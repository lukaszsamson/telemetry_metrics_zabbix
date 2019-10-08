# TelemetryMetricsZabbix

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

## Documentation

Docs can be found at [https://hexdocs.pm/telemetry_metrics_zabbix](https://hexdocs.pm/telemetry_metrics_zabbix).

## License

TelemetryMetricsZabbix source code is released under MIT License.
Check LICENSE file for more information.
