defmodule TelemetryMetricsZabbix.CollectorTest do
  use ExUnit.Case
  alias TelemetryMetricsZabbix.Collector

  test "counter metric counts events" do
    metric = Telemetry.Metrics.counter("some.name")

    assert 1 == Collector.init(metric, 123, 1_948_102)
    assert 124 == Collector.update(metric, 123, 54, 1_948_102)
    assert [124] == Collector.extract(metric, 124)
  end

  test "sum metric sums events values" do
    metric = Telemetry.Metrics.sum("some.name")

    assert 123 == Collector.init(metric, 123, 1_948_102)
    assert 177 == Collector.update(metric, 123, 54, 1_948_102)
    assert [124] == Collector.extract(metric, 124)
  end

  test "summary metric calculates average of events values" do
    metric = Telemetry.Metrics.summary("some.name")

    assert {123, 1} == Collector.init(metric, 123, 1_948_102)
    assert {88.5, 2} == Collector.update(metric, {123, 1}, 54, 1_948_102)
    assert [124] == Collector.extract(metric, {124, 2})
  end

  test "last value metric collects all values with timestamps" do
    metric = Telemetry.Metrics.last_value("some.name")

    assert [{123, 1_948_102}] == Collector.init(metric, 123, 1_948_102)

    assert [{54, 1_948_102}, {123, 1_948_102}] ==
             Collector.update(metric, [{123, 1_948_102}], 54, 1_948_102)

    assert [{54, 1_948_102}, {123, 1_948_102}] ==
             Collector.extract(metric, [{54, 1_948_102}, {123, 1_948_102}])
  end
end
