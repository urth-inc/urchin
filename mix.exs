defmodule Urchin.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/urth-inc/urchin"

  def project do
    [
      app: :urchin,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Urchin",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Urchin.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A Model Context Protocol (MCP) server library for Elixir, implementing the " <>
      "2025-11-25 specification over the Streamable HTTP transport."
  end

  defp package do
    [
      maintainers: ["Urth Inc."],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/develop/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md SECURITY.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "SECURITY.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end
end
