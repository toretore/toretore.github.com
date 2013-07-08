---
  title: Bottom-up Rails
  date: 2013-01-01
---


* MVC
* Controllers and views
* Helpers
* Models


This guide will cover the basic Ruby on Rails knowledge that you will need to get started. What it will not cover:

* AJAX or any other JavaScript-related 
* CSS or any layout-, UI- or UX-oriented

At the end of this guide, you will not have built an application, you will merely have learned how Rails works. It
will not be "test driven" as it's not the focus of this article and would only be a distraction at this point. The
point of this guide is to give you a solid footing from where you can develop basic Rails apps and explore more
complex subjects while having a good understanding of the structure that these rest upon.

Assumptions:

* You know Ruby. You MUST understand Ruby before reading this.
* You have installed Ruby with RubyGems properly and know how to use it
* You know HTTP basics; client-server dynamics. Specifically the statelessness of HTTP and the use of sessions and cookies to tie one request to another.
* You know your way around an interactive shell like Bash

Rails, Rack and HTTP
===

Rails is an HTTP appserver. It receives HTTP requests and sends back HTTP responses; at the very basic
it's not more complicated than that. Rails is what's known as Rack compliant: Rack is a very simple
specification for Ruby apps to interact with HTTP requests. This is a very basic Rack compliant service:

    class MyRackApp

      def call(env)
        [200, {'Content-Type' => 'text/html'}, ['Hello world']]
      end

    end

Rack applications don't interact with the network directly, they just know how to respond to a Rack compliant
call from a Rack compliant HTTP server. One such server is Thin (gem install thin), which can run a Rack
app like this:

    server = Thin::Server.new('0.0.0.0', '1234')
    server.app = MyRackApp.new
    server.start

You can send it requests using curl:

    curl http://127.0.0.1:1234/
    Hello world

If this were a Rails app, it would look something like this:

    require 'thin'
    require ::File.expand_path('../config/environment',  __FILE__)

    server = Thin::Server.new('0.0.0.0', '1234')
    server.app = Bottomsup::Application
    server.start

I.e. load a Rack-compliand HTTP server (Thin), load the Rails application, start up the HTTP server and tell it
to forward all its requests to a Rack-compliant application object (@Bottomsup::Application@).


MVC: Model-View-Controller
===

Rails is built upon the concept of separating the logic of your application into what is called models, views and
controllers. A request comes in to a controller


A note about scaffolding.
===

It's a complete waste of your time. You don't need to know what it is and you must not use it.
