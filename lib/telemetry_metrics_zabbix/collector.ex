defprotocol TelemetryMetricsZabbix.Collector do
  @moduledoc ~S"""
  A protocol handling metrics collection
  """

  @doc ~S"""
  Constructs initial metric value
  """
  @spec init(t, any, integer | nil) :: any
  def init(metric, value, timestamp)

  @doc ~S"""
  Constructs next metric value
  """
  @spec update(t, any, any, integer | nil) :: any
  def update(metric, prev_value, value, timestamp)

  @doc ~S"""
  Extrects collected metric value as list
  """
  @spec extract(t, any) :: list
  def extract(metric, value)
end

defimpl TelemetryMetricsZabbix.Collector, for: Telemetry.Metrics.Counter do
  @moduledoc ~S"""
  Collector implementation that counts events
  """

  @spec init(Telemetry.Metrics.Counter.t(), any, integer | nil) :: 1
  def init(%Telemetry.Metrics.Counter{}, _value, _timestamp), do: 1

  @spec update(Telemetry.Metrics.Counter.t(), integer, any, integer | nil) :: integer
  def update(%Telemetry.Metrics.Counter{}, prev_value, _value, _timestamp), do: prev_value + 1

  @spec extract(Telemetry.Metrics.Counter.t(), integer) :: [integer]
  def extract(%Telemetry.Metrics.Counter{}, value), do: [value]
end

defimpl TelemetryMetricsZabbix.Collector, for: Telemetry.Metrics.Sum do
  @moduledoc ~S"""
  Collector implementation that sums events' values
  """

  @spec init(Telemetry.Metrics.Sum.t(), number, integer | nil) :: number
  def init(%Telemetry.Metrics.Sum{}, value, _timestamp), do: value

  @spec update(Telemetry.Metrics.Sum.t(), number, number, integer | nil) :: number
  def update(%Telemetry.Metrics.Sum{}, prev_value, value, _timestamp), do: prev_value + value

  @spec extract(Telemetry.Metrics.Sum.t(), number) :: [number]
  def extract(%Telemetry.Metrics.Sum{}, value), do: [value]
end

defimpl TelemetryMetricsZabbix.Collector, for: Telemetry.Metrics.LastValue do
  @moduledoc ~S"""
  Collector implementation that takes all event's values with timestamps
  """

  @spec init(Telemetry.Metrics.LastValue.t(), any, integer | nil) :: [{any, integer | nil}]
  def init(%Telemetry.Metrics.LastValue{}, value, timestamp), do: [{value, timestamp}]

  @spec update(Telemetry.Metrics.LastValue.t(), list, any, integer | nil) :: list
  def update(%Telemetry.Metrics.LastValue{}, prev_value, value, timestamp),
    do: [{value, timestamp} | prev_value]

  @spec extract(Telemetry.Metrics.LastValue.t(), list) :: list
  def extract(%Telemetry.Metrics.LastValue{}, value), do: value
end

defimpl TelemetryMetricsZabbix.Collector, for: Telemetry.Metrics.Summary do
  @moduledoc ~S"""
  Collector implementation that calculates events' values average
  """

  @spec init(Telemetry.Metrics.Summary.t(), number, integer | nil) :: {number, integer}
  def init(%Telemetry.Metrics.Summary{}, value, _timestamp), do: {value, 1}

  @spec update(Telemetry.Metrics.Summary.t(), {number, integer}, number, integer | nil) ::
          {number, integer}
  def update(%Telemetry.Metrics.Summary{}, {prev_value, prev_n}, value, _timestamp) do
    n = prev_n + 1
    value = (prev_value * prev_n + value) / n
    {value, n}
  end

  @spec extract(Telemetry.Metrics.Summary.t(), {number, integer}) :: [number]
  def extract(%Telemetry.Metrics.Summary{}, {value, _}), do: [value]
end
