defmodule TelemetryMetricsZabbix.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukaszsamson/telemetry_metrics_zabbix"

  def project do
    [
      app: :telemetry_metrics_zabbix,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "TelemetryMetricsZabbix",
      source_url: @source_url,
      docs: [
        extras: ["README.md"],
        main: "readme",
        source_ref: "v#{@version}",
        source_url: @source_url
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry_metrics, "~> 0.3"},
      {:zabbix_sender, "~> 1.0"},
      {:mock, "~> 0.3", only: :test}
    ]
  end

  defp description do
    """
    Provides a Zabbix format reporter and server for Telemetry.Metrics definitions.
    """
  end

  defp package do
    [
      name: :telemetry_metrics_zabbix,
      files: ["lib", "mix.exs", ".formatter.exs", "README*", "LICENSE*"],
      maintainers: ["Łukasz Samson"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end