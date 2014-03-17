---
  title: Comprehensive logging with Rails
  date: 2013-07-07
  published: true
---

Log files. Nobody likes them. They can contain a lot of useful data, but getting
at that data is difficult. You can try parsing them, but the results are less
than perfect. Then if you add some more data to it, your parsing breaks. They're
not that useful for debugging either. Ever try figuring out what went wrong with
that one request 5 days ago? Or finding out exactly why 1 in 15 requests that
you think may be related to an external API fails?

Log files suffer from the too common fallacy that human-readable is always
better than machine-readable. And they're not even human-readable. What they lack
is structure. What we want is structure. Lots of delicious, structured data that
we can easily navigate for debugging, measuring or tracking.

This article will show how to set up a ZeroMQ logging infrastructure in a Rails
app and how to gather relevant data that will be pushed out. The main objective
is logging, but it goes pretty far on the sliding scale between logging and
instrumentation.

Setting up the logger is not that much work, but actually getting all the data
out of an app is, as you'll see, not straight forward.



## The ZeroMQ logger

First, we need to set up the ZeroMQ components so that they're ready to receive
our log entries and events. Everything is going to go through a single, global
`ZMQLogger` instance, which will look something like this:

~~~ruby
zmq_ctx = ZMQ::Context.new

class ZMQLogger

  def initialize(ctx)
    @context = ctx
    @push = @context.socket(ZMQ::PUSH)
    @push.connect('tcp://127.0.0.1:1234')
  end

  def log(atts)
    @push.send_strings("myapp.log.#{atts['type']}", JSON.dump(atts))
  end

  def emit(atts)
    @push.send_strings("myapp.event.#{atts['type']}", JSON.dump(atts))
  end

end

$ZMQ_LOGGER = ZMQLogger.new(zmq_ctx)
~~~

This is very simplified for the sake of clarity, the
[real file](https://gist.github.com/toretore/5943700#file-unicorn-rb) is quite
a bit more complex. It will also be different depending on what server you use,
the linked example is for Unicorn, inside a Unicorn config file. The `$ZMQ_LOGGER`
instance is set once each time Unicorn forks a worker process.

As you can see, a log entry or an event consists of two parts:

* A type, which is a period-delimited list of tokens, like domain names but
  with opposite "endianness", like `myapp.log.user.login` or `myapp.event.user.create`.
* The payload, which is a JSON document. I've tried to find a common structure,
  but that's not set in stone.

The JSON structure is something like this:

~~~json
{
  "id": "ytfda5sd5oijo8y832gi",
  "time": "2012-12-12 12:12:12.123+02:00",
  "type": "appname.http.login-failed",
  "source": "staging.web-01.1234",
  "message": "Login failed",
  "description": "User not found",
  "data": {
    "username": "bigdick45",
    "password": true,
    "reason": "user-not-found"
  }
}
~~~

HTTP information will be inside `data.http`, with `data.http.request` and
`data.http.response` containing request and response information.

The PUSH socket connects to a PULL endpoint, `tcp://127.0.0.01:1234` in the
example above. This allows us to have a single PULL socket which binds to the
same endpoint, and several PUSH sockets, one for each worker, that send its
messages to it. In this way, there is a single point, the PULL socket, where all
log entries and events are sent.

~~~
+----------+
|   PUSH   |------+
+----------+      |
                  |
+----------+      |       +----------+
|   PUSH   |------+-----> |   PULL   |
+----------+      |       +----------+
                  |
+----------+      |
|   PUSH   |------+
+----------+
~~~

With this set up, we can `$ZMQ_LOGGER.log( ... )` or `$ZMQ_LOGGER.emit( ... )`
from anywhere inside the app.


## Controller helpers

To make it easier, we'll add a few methods to `ApplicationController` that lets
us easily log or emit anything we want.


~~~ruby
def emit_event(atts)
  atts['data'] ||= {}
  atts['data']['http'] ||= {}
  atts['data']['http']['request-id'] ||= request.uuid
  $ZMQ_LOGGER.emit(atts)
rescue Exception => e
  logger.error "[LOGGING ERROR] #{e.class}: #{e.message}\n#{e.backtrace.map{|l|  "  #{l}"}.join("\n")}"
end

def log_message(atts)
  atts['data'] ||= {}
  atts['data']['http'] ||= {}
  atts['data']['http']['request-id'] ||= request.uuid
  $ZMQ_LOGGER.log(atts)
rescue Exception => e
  logger.error "[LOGGING ERROR] #{e.class}: #{e.message}\n#{e.backtrace.map{|l|  "  #{l}"}.join("\n")}"
end
~~~

These methods simply relay the call to `$ZMQ_LOGGER`, after adding
`data.http.request-id` if not already present. They will also rescue any exception
that may happen to prevent logging from causing a user-facing error. It can be
debated whether or not emitting events is critical enough to produce a user-facing
error, depending on what kind of events you're emitting.



## Logging requests

Now that we're able to log messages from inside a controller, we can set up
automatic logging of each request. This is pretty simple, we use a
`before_filter` to simply `log_message` the data we want. With this approach,
you can get most request data. That's already pretty good, there's lots of
useful information in the request data. But it would be nice to have access
to *everything*:

* Request data: headers, parameters, body
* Response data: headers, status, body
* Timing data
* Rails also makes available which SQL queries were run and which templates
  were rendered, with the time it took for each to execute.

It's already obvious that if we want response information, the `before_filter`
won't work. So what about an `after_filter`? Turns out it's not so easy getting
this information out of Rails, and it's time for some..

### Invasive surgery

The information we want is in there somewhere, we just have to cut it open,
figure out where it is and yank it out. With the help of a Rube Goldbergian
setup using Rack middleware and Rails instrumentation, it's possible.

The response data is for some reason not accessible inside Rails, even in an
`after_filter`. So we'll have to take a step back and go outside Rails to get
it. This means add a Rack middleware around the call which captures the data.


~~~ruby
class RequestInfoMiddleware


  def initialize(app)
    @app = app
  end


  def call(env)
    data_callbacks = []
    env['zmq-logger.get-data'] = ->(cb){ data_callbacks << cb }

    request_start = env['HTTP_X_REQUEST_START'] || env['HTTP_X_QUEUE_START']
    begin
      request_start = Time.at(request_start[2..-1].to_f) if request_start
      request_start = nil if request_start && (request_start > Time.now || request_start < (Time.now-3600)) #Sanity check
    rescue
      request_start = nil
    end

    start = Time.now
      status, headers, body = @app.call(env)
    stop = Time.now

    atts = {'status' => status, 'headers' => headers, 'rack_start' => start, 'rack_stop' => stop}
    atts['request_start'] = request_start if request_start

    data_callbacks.each{|cb| cb.call(atts) }
    [status, headers, body]
  end


end
~~~


Simple enough. It sends the request down the stack for Rails to process it
and captures the response. It even times how long it takes. But it doesn't
actually log anything; it doesn't have access to all the information we want.
We have two choices here: Either send the missing data back up, but that would
involve serializing it in special headers or something like that (must conform to
Rack interface), and there was another reason why I didn't do that which I've
since forgotten. The other option is to capture the response data and send it
back down the stack to Rails, which has all the other data.

So what it does is add a Proc to the Rack `env` which, when run, adds a callback
that will be run when the request has bubbled back up. This way, something
further down the stack can register a callback to get the response data. I'm not
sure whether this is kind of clever or the dumbest idea in the world, but it works.


To use this from somewhere further down in the stack, you'd register a listener
like so:

~~~ruby
env['zmq-logger.get-data'].call(->(data){
  # Do stuff with data
})
~~~

This callback would be called after the request was processed and a response had
been sent upstream. In this way, it reaches quite uncomfortably down into
something that is supposed to be done running.


Now, onto the other part of this hideous Rube Goldberg duo: Using Rails'
instrumentation to get data about queries and renders. Given the nature of Rails'
instrumentation, which uses a simple pub/sub implementation to publish data
to those who are interested, it's time some more callback action.


~~~ruby
class InstrumentationDataGatherer

  def initialize
    subscribe
  end


  def subscribe
    ActiveSupport::Notifications.subscribe do |*event|
      if event[0] == 'start_processing.action_controller'
        start(event)
      elsif event[0] == 'process_action.action_controller'
        done(event)
      elsif event[0] == 'zmq-logger.call-me'
        @callbacks << event[4] if @callbacks
      elsif event[0] == 'sql.active_record' && event[4][:name] != 'SCHEMA'
        @queries << event if @queries
      elsif event[0] == '!render_template.action_view'
        @renders << event if @renders
      end
    end
  end


  def start(event)
    @id = event[3]
    @queries = []
    @renders = []
    @callbacks = []
  end

  def done(event)
    @callbacks.each do |cb|
      atts = {
        'stop' => event[2],
        'start' => event[1],
        'controller' => event[4][:controller],
        'action' => event[4][:action],
        'queries' => @queries.map{|e| {'time' => e[2]-e[1], 'sql' => e[4][:sql]} },
        'renders' => @renders.map{|e| {'time' => e[2]-e[1], 'path' => e[4][:virtual_path]} }
      }

      atts['view_runtime'] = event[4][:view_runtime] / 1000.0 if event[4][:view_runtime]
      atts['db_runtime'] = event[4][:db_runtime] / 1000.0 if event[4][:db_runtime]

      cb.call(atts)
    end
  rescue => e
    Rails.logger.error "[LOGGER] #{e.class}: #{e.message}\n#{e.backtrace.map{|l|  "  #{l}"}.join("\n")}"
  end

end

InstrumentationDataGatherer.new
~~~


This class, which goes in an initializer file, sets up listeners for relevant
data, gathers it and relays it to its own listeners using a callback. It has to guess
when a request starts and ends by looking at the events, and can not make the
assumption that it is inside a request cycle at all (console, test run). To listen
for this data, you'd use:

~~~ruby
ActiveSupport::Notifications.instrument('zmq-logger.call-me', ->(atts){
  # Do stuff with atts
})
~~~

(I probably could have used Instrumentation's pub/sub functionality directly
instead of adding another layer of callbacks, but hey, what's another callback!)

Now we finally have all the data we want, and we can take..



### Another look at request logging

We now have 2 callback mechanisms: From the Rack middleware and from the Rails
instrumentation. If we register one callback with each, when both those
have returned, it means we have all the data necessary to actually send away a
log entry. So let's add a simple `before_filter` that sets up the callbacks.


~~~ruby
before_filter :setup_logging

def setup_logging
  @memory_before = memory_usage
  start = Time.now
  instr, mw = nil, nil
  ActiveSupport::Notifications.instrument('zmq-logger.call-me', ->(atts){
    instr = atts
    log_request(atts, mw) if mw
  })
  request.env['zmq-logger.get-data'].call(->(data){
    mw = data
    log_request(instr, data) if instr
  })
end
~~~

Now, when all the data is available, `log_request` will be called. Let's have a
look at it.


~~~ruby
def log_request(instr, mw)
  atts = {
    'type' => 'request',
    'data' => {
      'time' => mw['rack_stop']-mw['rack_start'],
      'timing' => {
        'rails_start' => instr['start'],
        'rails_stop' => instr['stop'],
        'rails_time' => instr['stop']-instr['start'],
        'rack_start' => mw['rack_start'],
        'rack_stop' => mw['rack_stop'],
        'rack_time' => mw['rack_stop']-mw['rack_start'],
        'rails_db_time' => instr['db_runtime'],
        'rails_view_time' => instr['view_runtime'],
        'custom' => timing_data_for_logging
      },
      'memory' => [@memory_before, memory_usage], #[start of request, end of request]
      'queries' => instr['queries'],
      'renders' => instr['renders'],
      'user' => {
        'id' => current_user && current_user.id,
        'username' => current_user && current_user.username
      },
      'http' => request_data_for_logging.merge(
        'response' => {
          'status' => mw['status'],
          'headers' => mw['headers'],
          'body' => false && mw['body'] # You may not want to log every response body
        }
      )
    }
  }

  if mw['request_start']
    atts['data']['timing'].merge!(
      'request_start' => mw['request_start'],
      'request_time' => atts['data']['timing']['rack_stop'] - mw['request_start'],
      'queue_time' => atts['data']['timing']['rack_start'] - mw['request_start']
    )
  end

  log_message(atts)
end
~~~


Quite long, but all it does is extract the relevant data into a hash and send it to `log_message`.



## Logging exceptions

Logging exceptions is a lot simpler. We just need to wait for one to occur,
then format it and throw it into the ether.


~~~ruby
rescue_from Exception, with: :handle_exception

def handle_exception(exception)
  if Rails.env.development?
    log_exception(exception)
    raise exception
  else
    begin
      log_exception(exception)
      respond_to do |format|
        format.html{ render file: Rails.root.join('public', '500.html'), layout: false, status: 500 }
      end
    rescue Exception => e
      logger.error "[EXCEPTION LOGGING EXCEPTION] #{e.class}: #{e.message}\n#{e.backtrace.map{|l|  "  #{l}"}.join("\n")}"
      render :text => "Inxception :(", status: 500
    end
  end
end


def log_exception(exception)
  atts = {
    'type' => 'exception',
    'message' => 'Uncaught exception',
    'description' => 'An unanticipated exception occured',
    'data' => {
      'exception' => {
        'type' => exception.class.name,
        'message' => exception.message,
        'backtrace' => exception.backtrace
      },
      'http' => request_data_for_logging
    }
  }

  log_message(atts)
end
~~~


Simple enough. One thing we should add is a separate handler for
`ActiveRecord::RecordNotFound` exceptions:


~~~ruby
rescue_from ActiveRecord::RecordNotFound, :with => :handle_not_found

def handle_not_found(exception)
  log_exception(exception)

  if true#Rails.env.production?
    respond_to do |format|
      format.html{ render file: Rails.root.join('public', '404.html'), layout: false, status: 404 }
      format.xml{ render xml: error_xml('The requested resource could not be found'), status: 404 }
    end
  else
    raise exception
  end
rescue Exception => e
  logger.error "[EXCEPTION LOGGING EXCEPTION] #{e.class}: #{e.message}\n#{e.backtrace.map{|l|  "  #{l}"}.join("\n")}"
  render :text => "Inxception :("
end
~~~


## Code

I've left quite a bit of code out here, which you can find in
[this gist](https://gist.github.com/toretore/5943700).



## Doing something useful with the data

I've only shown you how to gather and publish the data. If you don't create
that PULL socket, it's not going anywhere.

What you do with it is up to you. I take all the log messages and shove them
into ElasticSearch, the code for which can be found
[here](https://gist.github.com/toretore/5943700#file-zmq-elasticsearch-logger-rb).
You will notice that it connects to something called 'ZMQ FAN'; this is just a
little process that runs on each machine that gathers all the messages from the
PULL socket and published them (fans them out) on a PUB socket.
