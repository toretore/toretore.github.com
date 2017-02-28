---
title: Exploring Mongrel2 handlers with Ruby
date: 2013-02-10
published: true
---

Unlike the original Mongrel, which was written in Ruby, for Ruby, Mongrel2 uses ZeroMQ
as a communication channel between it and the request handlers. It is thus "language
agnostic": If you can use ZeroMQ sockets, you can write a Mongrel2 handler.

In this article, we'll explore how to interact with Mongrel2 from a Ruby handler.


Prerequisites
---

You'll need to install ZeroMQ and Mongrel2. If you're using Homebrew, you can simply

~~~
brew install zeromq
brew install mongrel2
~~~

I'm going to be using EventMachine on Ruby 1.9 in this article, with the following gems:

* eventmachine
* em-zeromq
* json
* em-websocket

You don't have to use EventMachine, there are [zmq](http://www.zeromq.org/bindings:ruby) and
[ffi-rzmq](http://www.zeromq.org/bindings:ruby-ffi) gems, and swapping out the EM parts should
be trivial.

How Mongrel2 handlers work
---

Mongrel2 communicates with handlers using ZeroMQ sockets. One socket pair is responsible for
sending requests from the server to the handler, and another pair for sending responses from
the handler to the server.


~~~
+-------------------+              +--------------------+
|      Server       |              |       Handler      |
|                   |              |                    |
| +--------------+  |              |  +--------------+  |
| |    [PUSH]    |--|-- Request ---|->|    [PULL]    |  |
| +--------------+  |              |  +--------------+  |
|                   |              |                    |
| +--------------+  |              |  +--------------+  |
| |    [SUB]     |<-|-- Response --|--|    [PUB]     |  |
| +--------------+  |              |  +--------------+  |
+-------------------+              +--------------------+
~~~

The server uses a PUSH socket to publish requests, that will be picked up by one of the handlers
listening with a PULL socket on the other end. When the handler is done processing the request,
it publishes the response on a PUB socket. The server will then receive the response on its SUB
socket and send it to the HTTP client.

This setup allows a N-N topology where several servers can communicate with several handlers. The
PUSH<>PULL for requests lets one or more servers publish requests that will be fairly distributed
among one or more handlers. When a server publishes a request, it includes its unique ID (UUID), and
it also subscribes to this UUID on its SUB socket. The handler then publishes the response on its
PUB socket, using the UUID of the originating server as the key, thus only the server that's
subscribed to that key will receive the response.


Configuring Mongrel2
---

Before we can start writing the handler, we need to set up Mongrel2. Mongrel2 uses an SQLite
database for its configuration, which can seem a little strange, but the reason behind it is
to make the configuration programmable. For now, you can just copy this into a file:

~~~python
handler = Handler(
  send_spec = "tcp://*:9999",
  send_ident = "7B0A2BF9-0DB2-4FEB-AD90-75C649B859FC",
  recv_spec = "tcp://*:9998",
  recv_ident = ""
)

main = Server(
    uuid="242DABD4-D5BE-4D16-A042-D4985C8095BD",
    access_log="/logs/access.log",
    error_log="/logs/error.log",
    chroot="./",
    default_host="localhost",
    name="test",
    pid_file="/run/mongrel2.pid",
    port=6767,
    hosts = [
        Host(name="localhost", routes={
            "/": handler
        })
    ]
)

servers = [main]
~~~

[View file on Gist](https://gist.github.com/toretore/35eb74a2cac3f214fd4b#file-mongrel2_config-py)

Then load the configuration into SQLite with:

~~~
m2sh load -config filename
~~~

This sets up an HTTP server running on localhost:6767, using a handler which receives requests
on tcp://\*:9999 and sends responses on tcp://\*:9998.

Start the server:

~~~
m2sh start -name test
~~~

If you want to know more about Mongrel2's overall structure and configuration, the
[guide](http://mongrel2.org/manual/book-finalch4.html#x6-210003) covers that.


Getting to know Mongrel2
---

Ok, let's get to some code. We'll start by creating the handler's PULL and PUB sockets, connecting
them to the TCP ports from the config.

~~~ruby
require 'eventmachine'
require 'em-zeromq'
require 'json'
require 'securerandom'

EM.run do

  context = EM::ZeroMQ::Context.new(1)

  requests = context.socket(ZMQ::PULL)
  requests.connect('tcp://127.0.0.1:9999')

  responses = context.socket(ZMQ::PUB)
  responses.connect('tcp://127.0.0.1:9998')
  responses.setsockopt(ZMQ::IDENTITY, SecureRandom.uuid)

  # The rest of the handler's code goes here

end#EM.run
~~~

Now we're listening for messages on our PULL socket and we have a PUB socket on which we
can send responses. I'm not going to include this code in the examples that follow, just
assume that the code goes where the comment says above.

First, let's just see what Mongrel2 is sending to our PULL socket.

~~~ruby
requests.on :message do |message|
  puts message.copy_out_string
end
~~~

We're just printing whatever is getting sent to STDOUT. Start the program,

~~~
ruby handler.rb
~~~

and send Mongrel2 a request using curl or similar:

~~~
curl http://localhost:6767/
~~~

(Your curl will just hang because we're not sending a response yet, just Ctrl-C it)

And you'll see something like this printed out from the handler process:

~~~
7B0A2BF9-0DB2-4FEB-AD90-75C649B859FC 4 / 238:{"PATH":"/","x-forwarded-for":"127.0.0.1","accept":"*/*","user-agent":"curl/7.21.4 (universal-apple-darwin11.0) libcurl/7.21.4 OpenSSL/0.9.8r zlib/1.2.5","host":"localhost:6767","METHOD":"GET","VERSION":"HTTP/1.1","URI":"/","PATTERN":"/"},0:,
~~~

Well, that's kinda weird. Some of it is obviously JSON, but what about the rest of it?
If you look at the UUID at the start of the message, you'll see that it's the same one
we used on the handler's `send_ident` in the config. It just tells us where this request
is coming from. The 1 right after it is the request ID, so Mongrel2 knows which client to
send the response to, and after that is the path the client requested. Everything after
that is encoded as [netstrings](http://cr.yp.to/proto/netstrings.txt). So, each request
uses this pattern:

~~~
[UUID] [Request ID] [Path] [Netstrings]
~~~

That is, four parts separated by spaces. That should be pretty easy to parse:

~~~ruby
requests.on :message do |msg|
  p msg.copy_out_string.split(' ', 4) #Limit to 4 items, i.e. stop when we get to the netstrings
end
~~~

Send it another request:

    curl http://localhost:6767/foo

And the handler prints:

~~~
["7B0A2BF9-0DB2-4FEB-AD90-75C649B859FC", "2", "/foo", "244:{\"PATH\":\"/foo\",\"x-forwarded-for\":\"127.0.0.1\",\"accept\":\"*/*\",\"user-agent\":\"curl/7.21.4 (universal-apple-darwin11.0) libcurl/7.21.4 OpenSSL/0.9.8r zlib/1.2.5\",\"host\":\"localhost:6767\",\"METHOD\":\"GET\",\"VERSION\":\"HTTP/1.1\",\"URI\":\"/foo\",\"PATTERN\":\"/\"},0:,"]
~~~

You might be thinking, "Well, this is obviously broken, what if the path has spaces in it?".
Well, Mongrel2 has solved this problem by decreeing that *paths may not have spaces in them*. It
will reject any requests that do not follow this rule.

So, now we have the UUID, the request ID, the path and the netstrings. Netstrings are
very simple (a number telling us how many bytes in the string, a colon,then the string,
and a comma), so we'll just write a quick and dirty parser:

~~~ruby
requests.on :message do |msg|
  uuid, id, path, rest =  msg.copy_out_string.split(' ', 4)

  netstrings = []                             #headers ,body              ,
  until rest.empty?                           #6:{JSON},15:hello my friend,
    length = rest[/\A\d+/]                    #6       #15
    rest.slice!(0, length.length+1)           #6:      #15:
    netstrings << rest.slice!(0, length.to_i) #{JSON}  #hello my friend
    rest.slice!(0)                            #,       #,
  end

  headers, body = netstrings
  headers = JSON.parse(headers)

  p headers
  p body
end
~~~

As you can see, there are two netstrings in a request. The first is a JSON representation of
the request headers and the second is the HTTP body (possibly an empty string). We can now
extend our description of the request message to include the netstrings:

    [UUID] [Request ID] [Path] [Netstring - HTTP headers as JSON],[Netstring - HTTP body],

Send the request again:

~~~
curl http://localhost:6767/foo

{"PATH"=>"/foo", "x-forwarded-for"=>"127.0.0.1", "accept"=>"*/*", "user-agent"=>"curl/7.21.4 (universal-apple-darwin11.0) libcurl/7.21.4 OpenSSL/0.9.8r zlib/1.2.5", "host"=>"localhost:6767", "METHOD"=>"GET", "VERSION"=>"HTTP/1.1", "URI"=>"/foo", "PATTERN"=>"/"}
""
~~~

With a body:

~~~
curl -XPOST -d"It's the way of the road, buddy." http://localhost:6767/

{"PATH"=>"/", "x-forwarded-for"=>"127.0.0.1", "content-type"=>"application/x-www-form-urlencoded", "content-length"=>"32", "accept"=>"*/*", "user-agent"=>"curl/7.21.4 (universal-apple-darwin11.0) libcurl/7.21.4 OpenSSL/0.9.8r zlib/1.2.5", "host"=>"localhost:6767", "METHOD"=>"POST", "VERSION"=>"HTTP/1.1", "URI"=>"/", "PATTERN"=>"/"}
"It's the way of the road, buddy.
~~~


Responses
---


Now that we've got the requests, let's get to responding. The response message is similar to
the request message. It includes the UUID of the server, the client ID and the HTTP response.

    [UUID] [Netstring: client IDs] [HTTP response]

Let's add a response to our test code:

~~~ruby
response_body = 'Hello, Mongrel2!'
response_body = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: #{response_body.bytesize}\r\n\r\n#{response_body}"
response = '%s %d:%s, %s' % [uuid, id.size, id, response_body]
responses.send_msg(response)
~~~

That's it. We have a fully functional Mongrel2 HTTP handler. Let's try curling it again, and enjoy
not seeing it hang as it's waiting for a response that never arrives:

~~~
curl -i http://localhost:6767/
HTTP/1.1 200 OK
Connection: close
Content-Length: 16

Hello, Mongrel2!
~~~

[View entire handler on Gist](https://gist.github.com/toretore/35eb74a2cac3f214fd4b#file-simple_handler-rb)


Server-Sent Events/EventSource
---

If you look closely at the response message definition above, you'll see that I used plural
"client IDs" in the netstring part. A handler can respond to more than one client; this is useful
for example in keep-alive connections where you want to send data to several clients listening
on their persistent HTTP connections. One use for this is Server-Sent Events (SSE), which is a
simple protocol for pushing events from a server to listening clients. An event looks like this:

    data: Text

Each event is followed by two newlines (\r\n\r\n), and may include lines for event ID and event type:

    id: 3
    event: message
    data: Hello my friend,
    data: how are you?

Each line is terminated by \r\n, and there may be several data lines. The JavaScript EventSource
implementation concatenates all data lines together as if it's a single multiline message.

Let's convert out handler to become a simple source of SSEs. The server will simply emit a neverending
source of events containing a counter that is increased by one for each time:

    event: counter
    data: 1

    event: counter
    data: 2

And so on.

The HTTP 1.1 specification says that a connection is to be regarded as persistent unless otherwise
is stated (by the use of the Connection: close and Content-Length headers). SSE just build on that
and defines the `text/event-stream` MIME type, telling a compatible client that this is an event
stream. Let's change our handler to return (or leave out) the appropriate headers.

~~~ruby
response_headers = {'Content-Type' => 'text/event-stream'}
response_body = "HTTP/1.1 200 OK\r\n#{response_headers.map{|k,v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n"
response = '%s %d:%s, %s' % [uuid, id.size, id, response_body]
responses.send_msg(response)
~~~

The client will now hang on to the connection, waiting for events to be pushed. To be able to push
events to all connected clients, we need to keep track of who's connected. Add an array above the
code responsible for listening to requests:

~~~ruby
clients = []
requests.on :message do |msg|
  #...
~~~

Then, swap out the response code from above with this:

~~~ruby
if headers['METHOD'] == 'JSON' && JSON.parse(body)['type'] == 'disconnect'
  clients.delete(id)
  puts "Client #{id} disconnected (#{clients.size} clients left)"
else
  clients << id

  response_headers = {'Content-Type' => 'text/event-stream'}
  response_body = "HTTP/1.1 200 OK\r\n#{response_headers.map{|k,v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n"
  response = '%s %d:%s, %s' % [uuid, id.size, id, response_body]
  responses.send_msg(response)

  puts "Client #{id} connected (currently #{clients.size} clients)"
end
~~~

When a client disconnects, Mongrel2 sends a special message containing a JSON body and a single
`METHOD` header. The JSON contains a single entry:

~~~json
{"type": "disconnect"}
~~~

We check for that and remove the client ID from the list.

If it's a regular request, i.e. the initial connection has been made, add the client ID
to the list and send the appropriate SSE headers. Now we have the client's ID and the
client knows to expect events from us. To generate events, we're just going to add an
interval timer that sends messages on the response PUB socket just like a regular response.
This interval must be placed outside the request handling code, otherwise a new interval
would be started for each new connection, but we only want a single interval that publishes
to all clients.

~~~ruby
end #End of request handling code: requests.on :message do |msg|

c = 0
EM.add_periodic_timer 1 do
  event = "event: counter\r\ndata: #{c+=1}\r\n\r\n"
  ids = clients.join(' ')
  responses.send_msg('%s %d:%s, %s' % ['7B0A2BF9-0DB2-4FEB-AD90-75C649B859FC', ids.size, ids, event])
end
~~~

It simply concatenates all client IDs and adds it as a netstring between the server UUID and the event data.
The event data is simple: An event type ("counter") and the payload (c += 1). The server's UUID is the one
from the send_ident in our handler config, and I've just hardcoded it for this example. We could keep lists
of clients for each server and publish the events to all servers, but this is good enough for now, we
only have this one server.

Fire up the handler again and initiate a couple of connections with curl:

    curl -i http://localhost:6767/
    HTTP/1.1 200 OK
    Content-Type: text/event-stream

    event: counter
    data: 3

    event: counter
    data: 4

You can connect multiple clients and they will all receive the same data. If you look at the handler's
STDOUT, you'll see it keeps track of clients connecting and disconnecting:

    Client 52 connected (currently 1 clients)
    Client 53 connected (currently 2 clients)
    Client 52 disconnected (1 clients left)
    Client 53 disconnected (0 clients left)

If you disconnect and connect again later, you'll notice the counter has kept increasing in the meantime.
The handler will just emit these events once a second, and listening clients will receive them. If no
clients are listening, Mongrel2 discards them. Actually, we'll be sending invalid responses to Mongrel2
since they won't have any client IDs. It would be polite to simply not send it to Mongrel2 if the clients
array is empty.

[View the entire SSE handler on Gist](https://gist.github.com/toretore/35eb74a2cac3f214fd4b#file-sse_handler-rb)


WebSockets
---

Server-Sent Events are great. But they do have one limitation - they're one way only, a client can't send
messages back to the server. WebSockets is an alternative protocol for two-way communication. It's a
little more involved than SSE, and getting it to work through Mongrel2 isn't straight forward.

Mongrel2 supports WebSockets. Kind of. WebSockets isn't built with HTTP: It pretends to be an HTTP
connection at first, which is then "upgraded" to WebSockets. There are many different versions of
the WebSockets specification, and Mongrel2 only supports the latest, version 13. Mongrel2 will
take care of (some of) the initial setup of the connection and the WebSockets handshake which upgrades
the HTTP connection to WebSockets. It will also decode incoming messages for you, but when you want
to send something back you have to take care of it yourself. This is also how it supports HTTP, but
for this article I don't want to get into creating WebSocket frames so we're going to hack something
in place which will take care of it for us. [em-websocket](https://github.com/igrigorik/em-websocket)
is a WebSockets implementation for EventMachine, and you can easily start a WS server using it. But
we want to go through Mongrel2, so we're going to shoehorn it into our Handler.

Let's replace the request handling code once again with this:

~~~ruby
if headers['METHOD'] == 'WEBSOCKET_HANDSHAKE'
  clients[id] = {websocket: EM::WebSocket::Connection.new(id, {})}
  (class << clients[id][:websocket];self;end).send(:define_method, :send_data){|d| responses.send_msg('%s %d:%s, %s' % [uuid, id.size, id, d]) }
  headers.delete_if{|k,v| k =~ /\A[A-Z]+\Z/ }#Delete Mongrel2 custom headers
  http = "GET / HTTP/1.1\r\n#{headers.map{|k,v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n#{body}"
  clients[id][:websocket].receive_data(http)
elsif headers['METHOD'] == 'WEBSOCKET'
  puts "Received WS message: #{body}"
end
~~~

I said it's a hack, remember?

Mongrel2 will detect an incoming WebSockets (v13) connection and set the `METHOD` header to
`WEBSOCKET_HANDSHAKE`. This is the initial connection where HTTP is upgraded to WebSockets. We're
going to let em-websocket take care of handling the connection by making it believe it's getting its
data from EventMachine. We instantiate a `EM::WebSocket::Connection`, then override that instance's
`send_data` to use our `responses` ZMQ socket. We store the connection instance for this client in
the `clients` hash (which used to be an array, you're going to have to change that). Then we give it
the incoming data so that it can respond to the handshake appropriately. From now on, we have a
full-duplex WebSocket connection.

Now, Mongrel2 is still going to decode incoming messages, putting the message payload in the body.
This is fine, as we've only redirected the connection's `send_data`, which we will be using
whenever we want to send a message to the client. When Mongrel2 receives a message after the
initial handshake, it will set `METHOD` to `WEBSOCKET`.

To test out your WebSocket, you can use the console in a browser which supports the latest version,
like Chrome 25:

~~~javascript
var socket = new WebSocket('ws://localhost:6767/')
socket.onmessage = function(msg){ console.log(msg); }
socket.send('Hello Mongrel2 from a WebSocket!');
~~~

To send something back:

~~~ruby
#...
elsif headers['METHOD'] == 'WEBSOCKET'
  puts "Received WS message: #{body}"
  clients[id][:websocket].send('Hello yourself, browser!')
end
~~~

If you spy on the TCP port while creating the WebSocket on the client, you'll see the "HTTP"
handshake:

    GET / HTTP/1.1
    Upgrade: websocket
    Connection: Upgrade
    Host: localhost:3457
    Origin: http://localhost:631
    Pragma: no-cache
    Cache-Control: no-cache
    Sec-WebSocket-Key: 0j8yo99R95ZY0P6rP3aTQQ==
    Sec-WebSocket-Version: 13
    Sec-WebSocket-Extensions: x-webkit-deflate-frame

    HTTP/1.1 101 Switching Protocols
    Upgrade: websocket
    Connection: Upgrade
    Sec-WebSocket-Accept: cqPlq0VWCRTVSpdkbcqHUeWNhU8=

After this you'll see how it's switched to WebSockets' binary protocol.


The chat example
---

No asynchronous messaging article would be complete without the ubiquitous chat example. We'll keep
it simple and only implement a simple JSON protocol without any real UI. Now that we have the WebSocket
up and running we can just alter the code slightly to show how it can be used for communication among
several peers through a central server (our handler).

~~~ruby
if headers['METHOD'] == 'WEBSOCKET_HANDSHAKE'
  clients[id] = {websocket: EM::WebSocket::Connection.new(id, {})}
  (class << clients[id][:websocket];self;end).send(:define_method, :send_data){|d| responses.send_msg('%s %d:%s, %s' % [uuid, id.size, id, d]) }
  headers.delete_if{|k,v| k =~ /\A[A-Z]+\Z/ }#Delete Mongrel2 custom headers
  http = "GET / HTTP/1.1\r\n#{headers.map{|k,v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n#{body}"
  clients[id][:websocket].receive_data(http)
elsif headers['METHOD'] == 'WEBSOCKET'
  data = JSON.parse(body)
  if data['type'] == 'join'
    clients[id][:name] = data['name']
    clients.each{|i,h| h[:websocket].send(JSON.generate(type: 'join', name:clients[id][:name])) }
    puts "#{data['name']} joined"
  elsif data['type'] == 'message'
    clients.each{|i,h| h[:websocket].send(JSON.generate(type: 'message', name:clients[id][:name], message:data['message'])) }
    puts "#{clients[id][:name]} said: #{data['message']}"
  end
else
  puts "Received HTTP request"
  response_body = "HTTP/1.1 418 I'm a teapot\r\nContent-Length: 0\r\nConnection: close\r\n\r\nNot really, I'm a WebSocket"
  responses.send_msg('%s %d:%s, %s' % [uuid, id.size, id, response_body])
end
~~~

The handshake part is still the same. Our JSON protocol uses a `type` attribute to signify what kind
of message we're dealing with; one `join` message with a `name` attribute and a `message` message
with a (you guessed it) `message` and a `name` attribute. Our response handler distributes each message among its
connected clients, who choose what action to take. You can initiate a chat using the browser console
with two sockets:

~~~javascript
var client = function(name){
  var socket = new WebSocket('ws://localhost:6767/');
  socket.onmessage = function(m){
    var json = JSON.parse(m.data);
    console.log(j['type'] == 'join' ? j['name']+' has joined' : j['name']+' said: '+j['message']);
  };
  socket.say = function(m){ this.send(JSON.stringify({type: 'message', message: m})); };
  socket.onopen = function(){ s.send(JSON.stringify({type: 'join', name: name})); };

  return socket;
};

var alice = client('alice'),
    bob = client('bob');

alice.say('hey bob');
bob.say('hiya there alice');
~~~

[View entire WS handler on Gist](https://gist.github.com/toretore/35eb74a2cac3f214fd4b#file-websockets_handler-rb)
