defmodule Certstream do
  @moduledoc """
  Certstream is a service for watching CT servers, parsing newly discovered certificates,
  and broadcasting updates to connected websocket clients.
  """
  use Application
  use GenServer

  def start(_type, _args) do
    children = [
      # Agents
      Certstream.AMQPManager,

      # Registry
      {Registry, [keys: :unique, name: Registry.URL]},

      # Watchers
      {DynamicSupervisor, name: DynamicSupervisor.Watcher, strategy: :one_for_one},

      # Application
      {Certstream, watcher_supervisor: DynamicSupervisor.Watcher, url_registry: Registry.URL}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__,
      %{:watcher_supervisor => opts[:watcher_supervisor], :url_registry => opts[:url_registry]}, name: Certstream)
  end

  def init(state) do
    send(self(), :work)

    {:ok, state}
  end

  def handle_info(:work, state) do
    Certstream.CTWatcher.start_and_link_watchers(state[:watcher_supervisor], state[:url_registry])

    Process.send_after(self(), :work, :timer.hours(1))

    {:noreply, state}
  end
end
