# vim: ts=2:sw=2

require Logger

defmodule Certstream.CTWatcherFatalException do
  defexception [:reason, :message]
end

defmodule Certstream.CTWatcher do
  @moduledoc """
  The GenServer responsible for watching a specific CT server. It ticks every 15 seconds via
  `schedule_update`, and uses Process.send_after to trigger new requests to see if there are
  any certificates to fetch and broadcast.
  """
  use GenServer

  @default_http_options [
    timeout: 10_000,
    recv_timeout: 10_000,
    follow_redirect: true,
    hackney: [:insecure]
  ]

  def child_spec(state) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [state]},
      restart: :temporary
    }
  end

  def start_and_link_watchers(supervisor_name, registry_name) do
    Logger.info("Initializing CT Watchers...")

    # Fetch all CT lists
    ctl_log_info =
      "https://www.gstatic.com/ct/log_list/v3/all_logs_list.json"
      |> invoke_http_request

    ctl_log_info
    |> Map.get("operators")
    |> Enum.each(fn operator ->
      operator
      |> Map.get("logs")
      |> Enum.each(fn log ->
        state = %{:operator => log, :registry_name => registry_name}
        DynamicSupervisor.start_child(supervisor_name, child_spec(state))
      end)
    end)
  end

  def start_link(opts) do
    registration = {:via, Registry, {opts[:registry_name], opts[:operator]["url"], :running}}

    GenServer.start_link(__MODULE__, opts, name: registration)
  end

  def init(state) do
    # Schedule the initial update to happen between 0 and 3 seconds from now in
    # order to stagger when we hit these servers and avoid a thundering herd sort
    # of issue upstream
    delay = :rand.uniform(100) / 10

    Logger.info(
      "Worker #{inspect(self())} started with URL #{state[:operator]["url"]} and initial start time of #{delay} seconds from now."
    )

    # On first run attempt to fetch 512 certificates, and see what the API returns. However
    # many certs come back is what we should use as the batch size moving forward (at least
    # in theory).
    state = Map.put(state, :batch_size, 512)

    Process.send_after(self(), :init, trunc(:timer.seconds(delay)))

    {:ok, state}
  end

  def invoke_http_request(full_url, options \\ @default_http_options, retry \\ true) do
    user_agent = {"User-Agent", user_agent()}

    Logger.debug("Sending GET request to #{full_url}")

    case HTTPoison.get(full_url, [user_agent], options) do
      {:ok, %HTTPoison.Response{status_code: 200} = response} ->
        case Jason.decode(response.body) do
          {:ok, term} ->
            term

          {:error, reason} ->
            message = "Parsing error: #{inspect(reason)} while GETing #{full_url}"
            Logger.error("#{message} . Terminating...")
            raise Certstream.CTWatcherFatalException, reason: :parsing_error, message: message
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        message = "Got too many requests status while GETing #{full_url}"

        if retry do
          delay = 150 + :rand.uniform(150)

          Logger.warn("#{message} . Sleeping for #{delay} seconds and trying again...")
          :timer.sleep(:timer.seconds(delay))
          invoke_http_request(full_url, options)
        else
          raise Certstream.CTWatcherFatalException, reason: :too_many_requests, message: message
        end

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        message = "Got not found status while GETing #{full_url}"
        Logger.error("#{message} . Terminating...")
        raise Certstream.CTWatcherFatalException, reason: :not_found, message: message

      {:ok, response} ->
        message = "Unexpected status code #{response.status_code} fetching url #{full_url}"

        if retry do
          Logger.error("#{message} . Sleeping for a bit and trying again...")
          :timer.sleep(:timer.seconds(10))
          invoke_http_request(full_url, options)
        else
          raise Certstream.CTWatcherFatalException, reason: :unexpected_status, message: message
        end

      {:error, %HTTPoison.Error{reason: :nxdomain}} ->
        message = "HTTP error: NXDOMAIN while GETing #{full_url}"
        Logger.error("#{message} . Terminating...")
        raise Certstream.CTWatcherFatalException, reason: :nxdomain, message: message

      {:error, %HTTPoison.Error{reason: reason}} ->
        message = "HTTP error: #{inspect(reason)} while GETing #{full_url}"

        if retry do
          Logger.error("#{message} . Sleeping for 60 seconds and trying again...")
          :timer.sleep(:timer.seconds(60))
          invoke_http_request(full_url, options)
        else
          raise Certstream.CTWatcherFatalException, reason: reason, message: message
        end
    end
  end

  def get_tree_size(state) do
    "#{state[:operator]["url"]}ct/v1/get-sth"
    |> invoke_http_request
    |> Map.get("tree_size")
  end

  def handle_info({:ssl_closed, _}, state) do
    Logger.info("Worker #{inspect(self())} got :ssl_closed message. Ignoring.")
    {:noreply, state}
  end

  def handle_info(:init, state) do
    batch_size = state[:batch_size]

    state =
      case batch_size > 1 do
        true ->
          try do
            batch_size =
              "#{state[:operator]["url"]}ct/v1/get-entries?start=0&end=#{batch_size - 1}"
              |> invoke_http_request(@default_http_options, false)
              |> Map.get("entries")
              |> Enum.count()

            Logger.info(
              "Worker #{inspect(self())} with URL #{state[:operator]["url"]} found batch size of #{batch_size}."
            )

            state = Map.put(state, :batch_size, batch_size)

            # On first run populate the state[:tree_size] key
            state = Map.put(state, :tree_size, get_tree_size(state))

            schedule_update()

            state
          rescue
            e in Certstream.CTWatcherFatalException ->
              case e.reason do
                :too_many_requests ->
                  batch_size = floor(batch_size * 0.9)
                  state = Map.put(state, :batch_size, batch_size)

                  Logger.warn(
                    "Reduced batch size for worker #{inspect(self())} with URL #{state[:operator]["url"]} to #{batch_size} because of too many requests."
                  )

                  Process.send_after(self(), :init, 10)

                  state

                _ ->
                  raise e
              end
          end

        false ->
          raise Certstream.CTWatcherFatalException,
            reason: :batch_size_unknown,
            message: "Unable to determine batch size for URL #{state[:operator]["url"]}"
      end

    {:noreply, state}
  end

  def handle_info(:update, state) do
    Logger.debug(fn -> "Worker #{inspect(self())} got tick." end)

    current_tree_size = get_tree_size(state)

    Logger.debug(fn -> "Tree size #{current_tree_size} - #{state[:tree_size]}" end)

    state =
      case current_tree_size > state[:tree_size] do
        true ->
          cert_count = current_tree_size - state[:tree_size]

          Logger.debug(
            "Worker #{inspect(self())} with URL #{state[:operator]["url"]} found #{cert_count} certificates [#{state[:tree_size]} -> #{current_tree_size}]."
          )

          broadcast_updates(state, current_tree_size)

          state
          |> Map.put(:tree_size, current_tree_size)
          |> Map.update(:processed_count, 0, &(&1 + (current_tree_size - state[:tree_size])))

        false ->
          state
      end

    schedule_update()

    {:noreply, state}
  end

  defp broadcast_updates(state, current_size) do
    certificate_count = current_size - state[:tree_size]
    certificates = Enum.to_list((current_size - certificate_count)..(current_size - 1))

    Logger.debug("Certificate count - #{certificate_count}")

    certificates
    |> Enum.chunk_every(state[:batch_size])
    # Use Task.async_stream to have 5 concurrent requests to the CT server to fetch
    # our certificates without waiting on the previous chunk.
    |> Task.async_stream(&fetch_and_broadcast_certs(&1, state),
      max_concurrency: 5,
      timeout: :timer.seconds(600)
    )
    # Nop to just pull the requests through async_stream
    |> Enum.to_list()
  end

  def fetch_and_broadcast_certs(ids, state) do
    Logger.debug(fn -> "Attempting to retrieve #{ids |> Enum.count()} entries" end)

    batch_count = Enum.count(ids)

    try do
      entries =
        "#{state[:operator]["url"]}ct/v1/get-entries?start=#{List.first(ids)}&end=#{List.last(ids)}"
        |> invoke_http_request
        |> Map.get("entries", [])

      entries
      |> Enum.zip(ids)
      |> Enum.map(fn {entry, cert_index} ->
        entry
        |> Certstream.CTParser.parse_entry()
        |> Map.merge(%{
          :cert_index => cert_index,
          :seen => :os.system_time(:microsecond) / 1_000_000,
          :source => %{
            :url => state[:operator]["url"],
            :name => state[:operator]["description"]
          },
          :cert_link =>
            "#{state[:operator]["url"]}ct/v1/get-entries?start=#{cert_index}&end=#{cert_index}"
        })
      end)
      |> Certstream.AMQPManager.submit()

      entry_count = Enum.count(entries)

      # If we have *unequal* counts the API has returned less certificates than our initial batch
      # heuristic. Drop the entires we retrieved and recurse to fetch others.
      if entry_count != batch_count do
        Logger.debug(fn ->
          "We didn't retrieve all the entries for this batch, fetching missing #{batch_count - entry_count} entries"
        end)

        fetch_and_broadcast_certs(ids |> Enum.drop(Enum.count(entries)), state)
      end
    rescue
      e in Certstream.CTWatcherFatalException ->
        case e.reason do
          :parsing_error ->
            if batch_count < 2 do
              ids_s = ids
              |> Enum.map(&to_string/1)
              |> Enum.join(", ")

              Logger.warn(
                "Unable to parse response - discarding entries with ID(s) #{ids_s}"
              )
            else
              split = ceil(batch_count / 2)

              Logger.warn(
                "Unable to parse response - splitting request into two batches of size #{split} and trying again..."
              )

              ids
              |> Enum.chunk_every(split)
              |> Enum.each(fn i -> fetch_and_broadcast_certs(i, state) end)
            end

          _ ->
            raise e
        end
    end
  end

  # Default to 10 second ticks
  defp schedule_update(seconds \\ 10) do
    # Note, we need to use Kernel.trunc() here to guarentee this is an integer
    # because :timer.seconds returns an integer or a float depending on the
    # type put in, :erlang.send_after seems to hang with floats for some
    # reason :(
    Process.send_after(self(), :update, trunc(:timer.seconds(seconds)))
  end

  # Allow the user agent to be overridden in the config, or use a default Certstream identifier
  defp user_agent do
    case Application.fetch_env!(:certstream_amqp, :user_agent) do
      :default -> "Certstream AMQP v#{Application.spec(:certstream, :vsn)}"
      user_agent_override -> user_agent_override
    end
  end
end
