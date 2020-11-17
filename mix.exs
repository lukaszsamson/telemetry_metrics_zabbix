defmodule TelemetryMetricsZabbix.MixProject do
  use Mix.Project

  @version "0.3.1"
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
      ],
      dialyzer: [
        flags: [
          # :unmatched_returns,
          :unknown,
          :error_handling,
          :race_conditions,
          :underspecs
        ]
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
      {:telemetry_metrics, "~> 0.6"},
      {:zabbix_sender, "~> 1.1"},
      # {:zabbix_sender, path: "~/zabbix_sender"},
      {:mock, "~> 0.3", only: :test},
      {:ex_doc, "~> 0.19", only: :dev},
      {:dialyxir, "~> 1.0.0", only: [:dev], runtime: false}
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
