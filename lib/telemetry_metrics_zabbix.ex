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

  Measurements are aggregated by event name, measurement and tag values. All those parts are included as Zabbix Sender Protocol key.
  Tag values are treated as Zabbix key parameters sorted by tag key.

  #### Example

  with metric

  ```elixir
  Telemetry.Metrics.sum("http.request.latency", tags: [:host, :method])
  ```

  and event

  ```elixir
  :telemetry.execute([:http, :request], %{latency: 200}, %{host: "localhost", method: "GET"})
  ```

  Zabbix key will be `http.request.latency["localhost","GET"]`
  """
  require Logger
  use GenServer
  alias TelemetryMetricsZabbix.Collector

  alias ZabbixSender.Protocol

  # Default application values
  @host "127.0.0.1"
  @port 10051
  @timestamping true
  @batch_window_size 1_000

  @type t :: %__MODULE__{
          host: String.t(),
          port: integer(),
          hostname: String.t(),
          timestamping: boolean,
          batch_window_size: integer(),
          data: %{},
          metrics: list(any),
          batch_timeout: reference | nil
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
  @spec init([Telemetry.Metrics.t()]) :: {:ok, t()}
  def init(metrics) do
    env = Application.get_env(:telemetry_metrics_zabbix, :config, [])
    host = Keyword.get(env, :host, @host)
    port = Keyword.get(env, :port, @port)
    timestamping = Keyword.get(env, :timestamping, @timestamping)
    batch_window_size = Keyword.get(env, :batch_window_size, @batch_window_size)
    hostname = Keyword.get(env, :hostname, "")

    for metric <- metrics, name_part <- metric.name do
      unless Regex.match?(~r/^[a-zA-Z0-9_]+$/, "#{name_part}") do
        raise ArgumentError, message: "invalid metric name #{metric.name}"
      end
    end

    Process.flag(:trap_exit, true)

    groups = Enum.group_by(metrics, & &1.event_name)

    excape_pattern = :binary.compile_pattern("\"")

    for {event, metrics} <- groups do
      :ok = :telemetry.attach(get_id(event), event, fn _event_name, measurements, metadata, metrics ->
        handle_event(measurements, metadata, metrics, excape_pattern)
      end, metrics)
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
  @spec terminate(any(), t()) :: :ok
  def terminate(_, %__MODULE__{metrics: metrics}) do
    for event <- metrics do
      :ok = :telemetry.detach(get_id(event))
    end

    :ok
  end

  defp get_id(event), do: {__MODULE__, event, self()}

  defp handle_event(measurements, metadata, metrics, escape_pattern) do
    for metric <- metrics do
      try do
        if keep?(metric, metadata) do
          measurement = extract_measurement(metric, measurements, metadata)
          tags = extract_tags(metric, metadata)

          key =
            metric.name
            |> Enum.map_join(".", &"#{&1}")

          tags_stringified =
            tags
            |> Enum.sort_by(fn {k, _v} -> k end)
            |> Enum.map_join(",", fn {_k, value} ->
              escaped_value = "#{value}" |> String.replace(escape_pattern, "\\\"")
              "\"" <> escaped_value <> "\""
            end)

          key =
            case tags_stringified do
              "" -> key
              _ -> key <> "[" <> tags_stringified <> "]"
            end

          report(key, measurement, metric)
        end
      rescue
        e ->
          Logger.error([
            "#{__MODULE__}: could not format metric #{inspect(metric)}\n",
            Exception.format(:error, e, __STACKTRACE__)
          ])
      end
    end
  end

  @spec keep?(Telemetry.Metrics.t(), map()) :: boolean()
  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end

  defp report(key, value, metric) do
    GenServer.cast(__MODULE__, {:report, key, value, metric, System.system_time(:second)})
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
    batch_timestamp = System.system_time(:second)

    messages =
      data
      |> Enum.flat_map(fn {key, {metric, value}} ->
        Collector.extract(metric, value)
        |> Enum.map(fn
          {v, timestamp} ->
            Protocol.value(hostname, key, v, if(timestamping, do: timestamp))

          v ->
            Protocol.value(hostname, key, v, if(timestamping, do: batch_timestamp))
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
    case ZabbixSender.send_values(values, timestamp, host, port) do
      {:ok, %{failed: 0, total: total}} ->
        Logger.debug("#{__MODULE__}: server processed #{total} messages")

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
