**Certstream-AMQP** is a service written in elixir to aggregate, parse, and stream certificate data from multiple [certificate transparency logs](https://www.certificate-transparency.org/what-is-ct). It leverages the amazing power of elixir/erlang to achieve great network throughput and concurrency with very little resource usage.

This is a rewrite of the [original version](https://github.com/CaliDog/certstream-server), and is a stripped-down version, which just pushes the certstream to AMQP queue.

## Getting Started

Getting up and running is pretty easy (especially if you use Heroku, as we include a Dockerfile!).

First install elixir (assuming you're on OSX, otherwise follow [instructions for your platform](https://elixir-lang.org/install.html))

```
$ brew install elixir
```

Then fetch the dependencies

```
$ mix deps.get
```

Perform configuration for AMQP broker

```
$ cd config
$ cp prod.exs.sample prod.exs
$ cp dev.exs.sample dev.exs
$ vim prod.exs
$ vim dev.exs
```

From there you can run it

```
$ mix run --no-halt
```

## Usage

Once you have the service running, the AMQP exchange is feed with certificate feed (lite version by default).

