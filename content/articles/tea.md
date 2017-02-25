---
title: Understanding the Elm Architecture
date: 2017-02-24
published: false
---

Elm is a pure, functional language with managed effects. This means that none of your Elm code will ever
directly cause effects. Here are some useful effects:

* Updating your application's state
* Rendering and updating the DOM
* Making HTTP calls
* Getting the current time (not technically an effect, but still impure)

As you can imagine, the vast majority of programs need to cause effects to be considered useful. Elm allows you
to tell it to cause effects for you: You give it a description of the effects you'd like to cause, and
Elm does it for you. A clear separation exists: Your code, the "inside world", and everything else, the
"outside world".

<div class="block">
  <img src="/images/tea-1.svg"/>
</div>


The Elm runtime is your link to the outside world: It is responsible for running your code, and it is the only
place where data crosses the boundary between the inside and outside worlds. Apart from this link to the
runtime, your code is completely isolated.

The runtime starts your program by calling a single function called `main`. In a browser-based GUI application,
this function will call one of several possible functions to initialize it. The one I will use as an example
is `Html.program`, as it embodies the "Elm Architecture" well without getting too complex:

~~~elm
program : { init : (model, Cmd msg)
          , update : msg -> model -> (model, Cmd msg)
          , subscriptions : model -> Sub msg
          , view : model -> Html msg }
          -> Program Never model msg
~~~

Specialized to the actual types most programs use by convention:

~~~elm
program : { init : (Model, Cmd Msg)
          , update : Msg -> Model -> (Model, Cmd Msg)
          , subscriptions : Model -> Sub Msg
          , view : Model -> Html Msg }
          -> Program Never Model Msg
~~~


You define 4 lifecycle functions and give them to `Html.program` as a record, and it will call these functions
at various points in your program's lifetime


<div class="block">
  <img src="/images/tea-2.svg"/>
</div>




Application state (the model)
--

Your code does not explicitly maintain any state, the inside world is stateless. The runtime is responsible
for maintaining state in the outside world, where this is allowed.

The state is contained in a single data structure, usually with the type `Model`:

~~~elm
type TodoItem = {
    title : String
  , done : Bool
  }

type alias Model = List TodoItem
~~~


When your program starts, the runtime will call `init` which returns the initial state:

~~~elm
init : (Model, Cmd Msg)
init = ([TodoItem "Procrastinate" True, TodoItem "Finish writing this article" False, TodoItem "Profit" False], Cmd.none)
~~~

`init` returns a tuple of `(Model, Cmd Msg)`. Ignore the `Cmd Msg` for now. The `Model` is returned by `init`
to the runtime, which saves this as the initial state of the application.

<div class="block">
  <img src="/images/tea-3.svg"/>
</div>

After initialization, the runtime listens for events in the outside world. Your program defines a list of events
that can happen:

~~~elm
type Msg
  = NewItem Item
  | RemoveItem Item
  | CheckItem Item
  | UncheckItem Item
~~~

When one of these events happen, the runtime will call your `update` function and pass it, along with the current
state:

~~~elm
update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  case msg of
    NewItem item ->
      (item :: items, Cmd.none)
    RemoveItem item ->
      (List.filter (\i -> i == item) items, Cmd.none)
    CheckItem item ->
      (List.map (\i -> if i == item then {i | done = True} else i) items, Cmd.none)
    UncheckItem item ->
      (List.map (\i -> if i == item then {i | done = False} else i) items, Cmd.none)
~~~

Typically, `update` will pattern match on the event, the `Msg`, to see which type of event it is and then do something
different for each event. Of course, *nothing is changed* inside `update` as it runs in the inside world where mutation
is forbidden. It will return a *new* value as part of the tuple `(Model, Cmd Msg)`. The runtime will receive this new
`Model` across the boundary and store it as the new state in the outside world.

<div class="block">
  <img src="/images/tea-4.svg"/>
</div>

You can imagine the runtime working something like this:

~~~javascript
// Initialize the state by calling `init`
var state = YourApp.init()[0];

onEvent(function(event){
  // When an event happens, run `update` and save the new state
  state = YourApp.update(event, state)[0];
});
~~~

The runtime is basically an event loop, and your `update` function is the callback.





Rendering to the DOM (the view)
--

It is not possible to interact with the DOM from the inside world. None of your Elm code can see the DOM, as it exists
only in the outside world. As with your application state, it is the runtime that's responsible for maintaining a
representation of your state in the DOM.

After it calls `init`, and after each call to `update`, the runtime will call your `view` function, passing it the
new state it's just received. `view` will then return a description of how you would like for the DOM to look, in
the form of a `Html Msg` value.

~~~elm
view : Model -> Html Msg
view model =
  todoItems model

todoItems : List TodoItem -> Html Msg
todoItems items =
  ul [] (List.map todoItem items)

todoItem : TodoItem -> Html Msg
todoItem item =
  li [classList [("checked", item.done)]] [text item.title]
~~~

An `Html Msg` represents a DOM node with attributes and zero or more child nodes. In the example, the list of
`TodoItem`s is turned into a `Html Msg` tree representing this HTML:

~~~html
<ul>
  <li class="checked">Procrastinate</li>
  <li>Finish writing this article</li>
  <li>Profit</li>
</ul>
~~~

The runtime will receive this description across the boundary and apply it to the actual DOM in the outside world.
This makes sure the state of the DOM always reflects the current state of the application.

<div class="block">
  <img src="/images/tea-5.svg"/>
</div>

The runtime now looks more like this:

~~~javascript
// Initialize the state by calling `init`
var state = YourApp.init()[0];

// The root node of our application's view
var root = document.body;

// Render the initial state to the DOM
root.innerHTML = renderDOM(YourApp.view(state));

onEvent(function(event){
  // When an event happens, run `update` and save the new state
  state = YourApp.update(event, state)[0];

  // Call `view` with the new state and apply the result to the DOM
  root.innerHTML = renderDOM(YourApp.view(state));
});
~~~




Where do events come from?
--

Events do not come from nothing. Nothing happens unless you instruct the runtime to do something that may
result in events happening. There are 3 sources of events:

* DOM events
* Commands
* Subscriptions



DOM events
---

In the node tree returned by your `view` function, you may include descriptions of DOM event handlers. When the
runtime sees these it will attach the necessary handlers to the DOM.

~~~elm
  todoItem : TodoItem -> Html Msg
  todoItem item =
    li [classList [("checked", item.done)], onClick (CheckItem item)] [text item.title]
~~~

The example has been changed to add an `onClick` handler to the virtual DOM node. When this is returned from
`view`, the runtime will apply it to the DOM:

~~~html
<ul>
  <li onClick="onEvent(CheckItem(state[0]))" class="checked">Procrastinate</li>
  <li onClick="onEvent(CheckItem(state[1]))">Finish writing this article</li>
  <li onClick="onEvent(CheckItem(state[2]))">Profit</li>
</ul>
~~~

The `Msg` part of `Html Msg` means that events of type `Msg` (and only this type) can originate from this node.
When a DOM event occurs, the runtime will translate this to one of the events you've listed as part of the `Msg`
type and call your `update` and `view` functions.




Commands
---

Commands are structures of the type `Cmd` that instruct the runtime to perform effects. A good example is making
an HTTP call:

~~~elm
type Msg =
  ...
  | TodoItemsResponse (Result Http.Error (List TodoItem))

fetchTodoItems : Cmd Msg
fetchTodoItems =
  Http.get "/todo-items.json" todoItemsDecoder
    |> Http.send TodoItemsResponse
~~~

Note the new event type that's been added to `Msg` and the use of `TodoItemsResponse` as an argument to `Http.send`.
The resulting `Cmd` will include information on how to construct a `Msg` that will be passed to your `update`
function. It is essentially a callback: You are only *describing* an effect that will happen at some point in the
future, and when it happens the runtime will notice this and call your `update` with the result:

~~~elm
update msg model =
  case msg of
    ...
    TodoItemsResponse result ->
      case result of
        Err error ->
          -- Ignore the error and just return the same model
          (model, Cmd.none)
        Ok items ->
          -- Update the model to be the new list of TodoItems
          (items, Cmd.none)
~~~

`Html.program`, as the mediator between the inside and the outside world, specifies 2 functions that may return a
`Cmd`:

~~~elm
program : { init : (Model, Cmd Msg)
          , update : Msg -> Model -> (Model, Cmd Msg)
          , subscriptions : Model -> Sub Msg
          , view : Model -> Html Msg }
          -> Program Never Model Msg
~~~

Both `init` and `update` return a tuple of `(Model, Cmd Msg)`. Most of the time, you will simply return `Cmd.none`,
which means "do nothing". But if you *do* want to cause an effect, this is where you must return the `Cmd`
representing your effect. You can create as many `Cmd`s as you want in the inside world, but unless you give then
to the runtime as a return value of these two functions, nothing happens.

The following `init` sets the initial state to be an empty list and returns a `Cmd` which
instructs the runtime to try and fetch the actual `TodoItem` list from the server:

~~~elm
init : (Model, Cmd Msg)
init = ([], fetchTodoItems)
~~~

When the server responds, the runtime will call `update` with the `TodoItemsResponse` which will update the model
if the response was successful.

<div class="block">
  <img src="/images/tea-6.svg"/>
</div>


The pretend-runtime updated to take commands into account:

~~~javascript
// Initialize the state by calling `init`
var [state, cmd] = YourApp.init();

// If a command was returned, execute it asynchronously
if (cmd) executeCmd(cmd, function(res){ onEvent(cmd.createMsg(res)); });

// The root node of our application's view
var root = document.body;

// Render the initial state to the DOM
root.innerHTML = renderDOM(YourApp.view(state));

onEvent(function(event){
  // When an event happens, run `update` and save the new state
  [state, cmd] = YourApp.update(event, state);

  // If a command was returned, execute it asynchronously
  if (cmd) executeCmd(cmd, function(res){ onEvent(cmd.createMsg(res)); });

  // Call `view` with the new state and apply the result to the DOM
  root.innerHTML = renderDOM(YourApp.view(state));
});
~~~





Subscriptions
---

Subscriptions are for repeating events. Some examples are WebSocket connections that represent a stream of
messages, or a "tick" event that occurs every second to update the inside world's time.

Subscriptions are represented by the `Sub Msg` type, and there is only 1 way to tell the runtime about your
interest in them: The `subscriptions` function executed by `Html.program`, which takes a `Model` and returns
a `Sub Msg`.

A simple example is `Time.every`, which returns a `Sub Msg` that results in an event containing the current
time every second:

~~~elm
type Msg =
  ...
  | Tick Time

update msg model =
  case msg of
    Tick time ->
      -- Do something with `time` here

subscriptions : Model -> Sub Msg
subscriptions model =
  Time.every Time.second Tick
~~~

The `subscriptions` function is called whenever the `Model` changes. If you're not an experienced functional
programmer, this may seem weird and even dangerous to you. But as you know, this function runs in the inside
world where everything is safe and pure: All it does is return a *description* of the repeating events you're
interested in. The runtime will check if that description has changed since the last time and reconcile its
internal state in the outside world if necessary.

<div class="block">
  <img src="/images/tea-7.svg"/>
</div>
