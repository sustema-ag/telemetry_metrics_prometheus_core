defmodule CoreTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  import TelemetryMetricsPrometheus.Core, only: [start_link: 1, scrape: 1, stop: 1]
  alias Telemetry.Metrics

  test "has a child spec" do
    child_spec = TelemetryMetricsPrometheus.Core.child_spec([metrics: []])

    assert child_spec == %{
      id: :prometheus_metrics,
      start: {TelemetryMetricsPrometheus.Core.Registry, :start_link,
              [
                [
                  validations: [consistent_units: true, require_seconds: true],
                  name: :prometheus_metrics,
                  monitor_reporter: false,
                  metrics: []
                ]
              ]}
    }

    assert %{id: :my_metrics} =
      TelemetryMetricsPrometheus.Core.child_spec([name: :my_metrics, metrics: []])
  end

  test "initializes properly" do
    metrics = [
      Metrics.counter("http.request.total",
        event_name: [:http, :request, :stop],
        tags: [:method, :code],
        description: "The total number of HTTP requests."
      )
    ]

    opts = [name: :test_reporter, validations: [require_seconds: false]]
    :ok = init_and_wait(metrics, opts)

    assert :ets.info(:test_reporter) != :undefined
    assert :ets.info(:test_reporter_dist) != :undefined

    :telemetry.execute([:http, :request, :stop], %{duration: 300_000_000}, %{
      method: "get",
      code: 200
    })

    metrics_scrape = scrape(:test_reporter)

    assert metrics_scrape =~ "http_request_total"
  end

  test "logs an error for duplicate metric types" do
    metrics = [
      Metrics.last_value("http.request.total"),
      Metrics.last_value("http.request.total")
    ]

    assert capture_log(fn ->
             opts = [name: :test_reporter, validations: false]
             :ok = init_and_wait(metrics, opts)
           end) =~ "Metric name already exists"
  end

  test "logs an error for unsupported metric types" do
    metrics = [
      Metrics.summary("http.request.duration")
    ]

    assert capture_log(fn ->
             opts = [name: :test_reporter, validations: false]
             :ok = init_and_wait(metrics, opts)
           end) =~ "Metric type summary is unsupported."
  end

  test "supports monitoring the health of the reporter itself" do
    :ok = init_and_wait([], name: :test_reporter, monitor_reporter: true, validations: false)
    children = DynamicSupervisor.which_children(TelemetryMetricsPrometheus.Core.DynamicSupervisor)

    assert Enum.any?(children, &match?({_, _, :worker, [:telemetry_poller]}, &1))
    stop(:test_reporter)
  end

  test "reporter health monitoring is off by default" do
    :ok = init_and_wait([], name: :test_reporter, validations: false)
    TelemetryMetricsPrometheus.Core.Registry.config(:test_reporter)
    children = DynamicSupervisor.which_children(TelemetryMetricsPrometheus.Core.DynamicSupervisor)

    refute Enum.any?(children, &match?({_, _, :worker, [:telemetry_poller]}, &1))
    stop(:test_reporter)
  end

  test "doesn't interfere with other telemetry_poller instances by default" do
    :ok = init_and_wait([], name: :test_reporter, validations: false, monitor_reporter: true)
    children = DynamicSupervisor.which_children(TelemetryMetricsPrometheus.Core.DynamicSupervisor)

    assert Enum.any?(children, &match?({_, _, :worker, [:telemetry_poller]}, &1))

    result =
      start_supervised(
        {:telemetry_poller, [period: 10, measurements: [], vm_measurements: [:memory]]}
      )

    assert elem(result, 0) == :ok
    stop(:test_reporter)
  end

  defp init_and_wait(metrics, opts) do
    {:ok, pid} = start_link(Keyword.put(opts, :metrics, metrics))
    _ = :sys.get_state(pid)
    :ok
  end
end