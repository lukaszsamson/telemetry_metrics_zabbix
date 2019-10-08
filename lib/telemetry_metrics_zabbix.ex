defmodule TelemetryMetricsZabbix do
  @moduledoc """
  Provides a Zabbix format reporter and server for Telemetry.Metrics definitions.

  ## Installation

  The package can be installed by adding `telemetry_metrics_zabbix` to your list of dependencies in `mix.exs`:

  ```elixir
  def deps do
    [
      {:telemetry_metrics_zabbix, "~> 0.1"}
    ]
  end
  ```

  ## Configuration

  Add approperiate config section to your `config.exs`

  ```elixir
  config :telemetry_metrics_zabbix, :config,
    host: "zabbix.trapper.host",
    port: 10051,
    hostname: "monitored.host",
    batch_window_size: 1000,
    timestamping: true
  ```

  ## Usage

  Add `TelemetryMetricsZabbix` to your application supervision tree and pass metrics as a param.

  ### Example

  ```elixir
  metrics = [
    Telemetry.Metrics.sum("http.request.latency", tags: [:host])
  ]

  children = [
    {TelemetryMetricsZabbix, metrics: metrics}
  ]
  opts = [strategy: :one_for_one, name: MyApp]
  Supervisor.start_link(children, opts)
  ```

  ### Currently supported metrics

  - `Telemetry.Metrics.Counter`: counts events
  - `Telemetry.Metrics.Sum`: sums events' values
  - `Telemetry.Metrics.Summary`: calculates events' values average
  - `Telemetry.Metrics.LastValue`: returns all events' values with timestamps

  ### Measuremet to zabbix value conversion

  Measurements are aggregated by event name, measurement and tag values. All those parts are included as Zabbix Sender Protocol key

  #### Example

  with metric

  ```elixir
  Telemetry.Metrics.sum("http.request.latency", tags: [:host])
  ```

  and event

  ```elixir
  :telemetry.execute([:http, :request], %{latency: 200}, %{host: "localhost"})
  ```

  Zabbix key will be `http.request.latency.localhost`
  """
  require Logger
  use GenServer
  alias TelemetryMetricsZabbix.Collector

  # Default application values
  @host "127.0.0.1"
  @port 10051
  @timestamping true
  @batch_window_size 1_000

  @type t :: %__MODULE__{
          host: String.t(),
          port: Integer.t(),
          hostname: String.t(),
          timestamping: boolean,
          batch_window_size: Integer.t(),
          data: %{},
          metrics: list(any),
          batch_timeout: reference
        }
  defstruct [
    :host,
    :port,
    :hostname,
    :timestamping,
    :batch_window_size,
    :data,
    :metrics,
    :batch_timeout
  ]

  def start_link(opts) do
    metrics =
      opts[:metrics] ||
        raise ArgumentError, "the :metrics option is required by #{inspect(__MODULE__)}"

    GenServer.start_link(__MODULE__, metrics, name: opts |> Keyword.get(:name, __MODULE__))
  end

  @impl true
  def init(metrics) do
    env = Application.get_env(:telemetry_metrics_zabbix, :config, [])
    host = Keyword.get(env, :host, @host)
    port = Keyword.get(env, :port, @port)
    timestamping = Keyword.get(env, :timestamping, @timestamping)
    batch_window_size = Keyword.get(env, :batch_window_size, @batch_window_size)
    hostname = Keyword.get(env, :hostname, "")

    {:ok,
     %__MODULE__{
       host: host,
       port: port,
       hostname: hostname,
       timestamping: timestamping,
       batch_window_size: batch_window_size,
       data: []
     }}

    Process.flag(:trap_exit, true)
    groups = Enum.group_by(metrics, & &1.event_name)

    for {event, metrics} <- groups do
      id = {__MODULE__, event, self()}
      :ok = :telemetry.attach(id, event, &handle_event/4, metrics)
    end

    {:ok,
     %__MODULE__{
       host: host,
       port: port,
       hostname: hostname,
       timestamping: timestamping,
       batch_window_size: batch_window_size,
       data: %{},
       metrics: Map.keys(groups)
     }}
  end

  @impl true
  def terminate(_, %__MODULE__{metrics: metrics}) do
    for event <- metrics do
      id = {__MODULE__, event, self()}
      :ok = :telemetry.detach(id)
    end

    :ok
  end

  defp handle_event(_event_name, measurements, metadata, metrics) do
    for metric <- metrics do
      try do
        measurement = extract_measurement(metric, measurements)
        tags = extract_tags(metric, metadata)

        key =
          metric.name
          |> Kernel.++(tags |> Map.values())
          |> Enum.map_join(".", &"#{&1}")

        report(key, measurement, metric)
      rescue
        e ->
          Logger.error([
            "#{__MODULE__}: could not format metric #{inspect(metric)}\n",
            Exception.format(:error, e, System.stacktrace())
          ])
      end
    end
  end

  defp extract_measurement(metric, measurements) do
    case metric.measurement do
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end

  defp report(key, value, metric) do
    GenServer.cast(__MODULE__, {:report, key, value, metric, :erlang.system_time(:seconds)})
  end

  @impl true
  def handle_cast(
        {:report, key, value, metric, timestamp},
        %__MODULE__{
          batch_timeout: batch_timeout,
          batch_window_size: batch_window_size,
          data: data
        } = state
      ) do
    batch_timeout = maybe_schedule_batch_send(batch_timeout, batch_window_size, data == %{})

    data =
      Map.update(data, key, {metric, Collector.init(metric, value, timestamp)}, fn {_, prev_value} ->
        {metric, Collector.update(metric, prev_value, value, timestamp)}
      end)

    {:noreply, %__MODULE__{state | data: data, batch_timeout: batch_timeout}}
  end

  @impl true
  def handle_info(
        {:zabbix, :send},
        %__MODULE__{data: data, timestamping: timestamping, hostname: hostname} = state
      ) do
    batch_timestamp = :erlang.system_time(:seconds)

    messages =
      data
      |> Enum.flat_map(fn {key, {metric, value}} ->
        Collector.extract(metric, value)
        |> Enum.map(fn
          {v, timestamp} ->
            ZabbixSender.Protocol.value(hostname, key, v, if(timestamping, do: timestamp))

          v ->
            ZabbixSender.Protocol.value(hostname, key, v, if(timestamping, do: batch_timestamp))
        end)
      end)

    messages
    |> send(batch_timestamp, state)

    {:noreply, %__MODULE__{state | data: %{}, batch_timeout: nil}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  # send_after when batch is empty
  defp maybe_schedule_batch_send(nil, bws, true) do
    Process.send_after(self(), {:zabbix, :send}, bws)
  end

  defp maybe_schedule_batch_send(reference, _, _), do: reference

  defp send(values, timestamp, %__MODULE__{host: host, port: port}) do
    serialized_message =
      values
      |> ZabbixSender.Protocol.encode_request(timestamp)
      |> ZabbixSender.Serializer.serialize()

    with {:ok, response} <- ZabbixSender.send(serialized_message, host, port),
         {:ok, deserialized} <- ZabbixSender.Serializer.deserialize(response),
         {:ok, %{failed: 0, total: total}} <- ZabbixSender.Protocol.decode_response(deserialized) do
      Logger.debug("#{__MODULE__}: server processed #{total} messages")
    else
      {:ok, %{failed: failed, total: total}} ->
        keys =
          values
          |> Enum.map(fn %{key: key} -> key end)
          |> Enum.uniq()

        Logger.warn(
          "#{__MODULE__}: server could not process #{failed} out of #{total} messages. Message keys was: #{
            inspect(keys, limit: :infinity)
          }"
        )

      {:error, reason} ->
        Logger.warn("#{__MODULE__}: could not send messages due to #{inspect(reason)}")
    end
  end
end
