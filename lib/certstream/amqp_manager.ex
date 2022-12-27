require Logger

defmodule Certstream.AMQPManager do
  @moduledoc """
  A GenServer responsible for broadcasting to AMQP. Uses :pobox to
  provide buffering and eventually drops messages if the backpressure isn't enough.
  """
  use GenServer
  use AMQP

  @exchange Application.fetch_env!(:amqp, :exchange)

  @pobox_buffer_size 10000
  @pobox_flush_threshold @pobox_buffer_size * 0.5
  @pobox_interval_seconds 3

  def start_link(_opts) do
    Logger.info("Starting #{__MODULE__}")

    GenServer.start_link(__MODULE__, fn -> %{} end, name: __MODULE__)
  end

  def init(_state) do
    {:ok, box_pid} = :pobox.start_link(__MODULE__, @pobox_buffer_size, :stack, :passive)

    {:ok, %{:box_pid => box_pid}}
  end

  def submit(entries), do: GenServer.cast(__MODULE__, {:submit, entries})

  def handle_info(:pobox_flush, state) do
    if Map.has_key?(state, :queued) do
      :pobox.active(state[:box_pid], fn msg, _ -> {{:ok, msg}, :nostate} end, :nostate)
      state = Map.delete(state, :queued)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:mail, _box_pid, :new_data}, state) do
    cond do
      not Map.has_key?(state, :error) and :pobox.usage(state[:box_pid]) > @pobox_flush_threshold ->
        state = Map.put(state, :queued, :os.system_time(:microsecond) / 1_000_000)
        send(self(), :pobox_flush)

        {:noreply, state}

      not Map.has_key?(state, :queued) ->
        state = Map.put(state, :queued, :os.system_time(:microsecond) / 1_000_000)
        Process.send_after(self(), :pobox_flush, trunc(:timer.seconds(@pobox_interval_seconds)))

        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:mail, _box_pid, serialized_certificates_lite, _message_count, message_drop_count},
        state
      ) do
    if message_drop_count > 0 do
      Logger.warn("Dropped #{message_drop_count} messages")
    end

    with {:ok, amqp} <- AMQP.Application.get_channel(:amqp_channel) do
      failed =
        serialized_certificates_lite
        |> List.flatten()
        |> Enum.reduce([], fn serialized_certificate_lite, failed ->
          case AMQP.Basic.publish(amqp, @exchange, "", serialized_certificate_lite) do
            :ok ->
              failed

            {:error, _reason} ->
              [serialized_certificate_lite | failed]
          end
        end)

      cond do
        length(failed) > 0 ->
          {:ok, state} = handle_error("publish error", failed, state)
          {:noreply, state}

        Map.has_key?(state, :error) ->
          state = Map.delete(state, :error)
          {:noreply, state}

        true ->
          {:noreply, state}
      end
    else
      {:error, reason} ->
        {:ok, state} = handle_error(reason, serialized_certificates_lite, state)

        {:noreply, state}
    end
  end

  def handle_error(reason, messages, state) do
    Logger.error("Requeuing #{length(messages)} messages due to error: #{reason}")

    Enum.each(messages, fn m -> :pobox.post(state[:box_pid], m) end)

    state = Map.put(state, :queued, :os.system_time(:microsecond) / 1_000_000)
    state = Map.put(state, :error, :os.system_time(:microsecond) / 1_000_000)
    Process.send_after(self(), :pobox_flush, trunc(:timer.seconds(@pobox_interval_seconds)))

    {:ok, state}
  end

  def handle_cast({:submit, entries}, state) do
    Logger.debug("Broadcasting #{length(entries)} certificates via AMQP")

    certificates =
      entries
      |> Enum.map(&%{:message_type => "certificate_update", :data => &1})

    certificates_lite =
      certificates
      |> Enum.map(&remove_chain_from_cert/1)
      |> Enum.map(&remove_der_from_cert/1)

    serialized_certificates_lite =
      certificates_lite
      |> Enum.map(&Jason.encode!/1)

    Enum.each(serialized_certificates_lite, fn m -> :pobox.post(state[:box_pid], m) end)
    :pobox.notify(state[:box_pid])

    {:noreply, state}
  end

  def remove_chain_from_cert(cert) do
    cert
    |> pop_in([:data, :chain])
    |> elem(1)
  end

  def remove_der_from_cert(cert) do
    # Clean the der field from the leaf cert
    cert
    |> pop_in([:data, :leaf_cert, :as_der])
    |> elem(1)
  end
end
