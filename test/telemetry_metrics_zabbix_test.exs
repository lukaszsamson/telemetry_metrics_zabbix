defmodule TelemetryMetricsZabbixTest do
  use ExUnit.Case, async: false
  doctest TelemetryMetricsZabbix
  import Telemetry.Metrics
  import Mock
  import ExUnit.CaptureLog

  test "starts" do
    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: [], name: :some_name)
    assert Process.whereis(:some_name) == pid
  end

  test "subscribes and unsubscribes to events" do
    metrics = [
      last_value("vm.memory.binary", unit: :byte),
      counter("vm.memory.total"),
      summary("http.request.response_time",
        tag_values: fn %{foo: :bar} -> %{bar: :baz} end,
        tags: [:bar]
      )
    ]

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)

    assert [
             %{
               config: [
                 %Telemetry.Metrics.LastValue{
                   name: [:vm, :memory, :binary]
                 },
                 %Telemetry.Metrics.Counter{
                   name: [:vm, :memory, :total]
                 }
               ],
               event_name: [:vm, :memory],
               id: {TelemetryMetricsZabbix, [:vm, :memory], ^pid}
             }
           ] = :telemetry.list_handlers([:vm, :memory])

    ref = Process.monitor(pid)
    Process.exit(pid, :normal)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
    end

    assert [] = :telemetry.list_handlers([:vm, :memory])
  end

  test "schedules batch send on first event" do
    metrics = [
      counter("vm.memory.total")
    ]

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)
    :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{})

    assert %TelemetryMetricsZabbix{batch_timeout: bt, data: data} = :sys.get_state(pid)
    assert is_reference(bt)

    assert %{
             "vm.memory.total" =>
               {%Telemetry.Metrics.Counter{
                  name: [:vm, :memory, :total]
                }, 1}
           } = data
  end

  test "sends batch on timeout" do
    metrics = [
      counter("vm.memory.total")
    ]

    Application.put_env(:telemetry_metrics_zabbix, :config,
      batch_window_size: 10,
      hostname: "myhost"
    )

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)

    with_mock ZabbixSender,
      send: fn msg, "127.0.0.1", 10051 ->
        {:ok, deserialized} = ZabbixSender.Serializer.deserialize(msg)

        assert [%{"clock" => _, "host" => "myhost", "key" => "vm.memory.total", "value" => "1"}] =
                 deserialized["data"]

        {:ok,
         ZabbixSender.Serializer.serialize(%{
           response: "success",
           info: "processed: 1; failed: 0; total: 1; seconds spent: 0.000055"
         })}
      end do
      assert capture_log(fn ->
               :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{})

               Process.sleep(20)

               assert %TelemetryMetricsZabbix{batch_timeout: nil, data: data} =
                        :sys.get_state(pid)

               assert data == %{}
             end) =~ "server processed 1 messages"
    end
  end

  test "warns when zabbix can't process some messages" do
    metrics = [
      counter("vm.memory.total")
    ]

    Application.put_env(:telemetry_metrics_zabbix, :config,
      batch_window_size: 10,
      hostname: "myhost"
    )

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)

    with_mock ZabbixSender,
      send: fn msg, "127.0.0.1", 10051 ->
        {:ok, deserialized} = ZabbixSender.Serializer.deserialize(msg)

        assert [%{"clock" => _, "host" => "myhost", "key" => "vm.memory.total", "value" => "1"}] =
                 deserialized["data"]

        {:ok,
         ZabbixSender.Serializer.serialize(%{
           response: "success",
           info: "processed: 0; failed: 1; total: 1; seconds spent: 0.000055"
         })}
      end do
      assert capture_log(fn ->
               :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{})

               Process.sleep(20)

               assert %TelemetryMetricsZabbix{batch_timeout: nil, data: data} =
                        :sys.get_state(pid)

               assert data == %{}
             end) =~
               "server could not process 1 out of 1 messages. Message keys was: [\"vm.memory.total\"]"
    end
  end

  test "logs error when zabbix sender returns error" do
    metrics = [
      counter("vm.memory.total")
    ]

    Application.put_env(:telemetry_metrics_zabbix, :config,
      batch_window_size: 10,
      hostname: "myhost"
    )

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)

    with_mock ZabbixSender,
      send: fn msg, "127.0.0.1", 10051 ->
        {:ok, deserialized} = ZabbixSender.Serializer.deserialize(msg)

        assert [%{"clock" => _, "host" => "myhost", "key" => "vm.memory.total", "value" => "1"}] =
                 deserialized["data"]

        {:error, :econnrefused}
      end do
      assert capture_log(fn ->
               :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{})

               Process.sleep(20)

               assert %TelemetryMetricsZabbix{batch_timeout: nil, data: data} =
                        :sys.get_state(pid)

               assert data == %{}
             end) =~ "not send messages due to :econnrefused"
    end
  end

  test "metrics are aggregated per event" do
    metrics = [
      sum("vm.memory1.total"),
      sum("vm.memory2.total")
    ]

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)
    :telemetry.execute([:vm, :memory1], %{binary: 100, total: 200}, %{})
    :telemetry.execute([:vm, :memory2], %{binary: 100, total: 250}, %{})

    assert %TelemetryMetricsZabbix{batch_timeout: bt, data: data} = :sys.get_state(pid)
    assert is_reference(bt)

    assert %{
             "vm.memory1.total" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory1, :total]
                }, 200},
             "vm.memory2.total" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory2, :total]
                }, 250}
           } = data
  end

  test "metrics are aggregated per measurement" do
    metrics = [
      sum("vm.memory.total"),
      sum("vm.memory.binary")
    ]

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)
    :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{})

    assert %TelemetryMetricsZabbix{batch_timeout: bt, data: data} = :sys.get_state(pid)
    assert is_reference(bt)

    assert %{
             "vm.memory.total" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory, :total]
                }, 200},
             "vm.memory.binary" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory, :binary]
                }, 100}
           } = data
  end

  test "metrics are aggregated per tag" do
    metrics = [
      sum("vm.memory.total", tags: [:device])
    ]

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)
    :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{device: "dev1"})
    :telemetry.execute([:vm, :memory], %{binary: 100, total: 250}, %{device: "dev2"})

    assert %TelemetryMetricsZabbix{batch_timeout: bt, data: data} = :sys.get_state(pid)
    assert is_reference(bt)

    assert %{
             "vm.memory.total[\"dev1\"]" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory, :total]
                }, 200},
             "vm.memory.total[\"dev2\"]" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory, :total]
                }, 250}
           } = data
  end

  test "keep/drop is supported" do
    metrics = [
      sum("vm.memory.total",
        tags: [:device],
        drop: fn metadata ->
          metadata[:boom] == :pow
        end
      )
    ]

    assert {:ok, pid} = TelemetryMetricsZabbix.start_link(metrics: metrics)
    :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{device: "dev1"})
    :telemetry.execute([:vm, :memory], %{binary: 100, total: 250}, %{device: "dev2", boom: :pow})

    assert %TelemetryMetricsZabbix{batch_timeout: bt, data: data} = :sys.get_state(pid)
    assert is_reference(bt)

    assert %{
             "vm.memory.total[\"dev1\"]" =>
               {%Telemetry.Metrics.Sum{
                  name: [:vm, :memory, :total]
                }, 200}
           } = data

    refute data |> Map.has_key?("vm.memory.total[\"dev2\"]")
  end
end
