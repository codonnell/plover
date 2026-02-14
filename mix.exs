defmodule Plover.MixProject do
  use Mix.Project

  def project do
    [
      app: :plover,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:ssl]],
      usage_rules: usage_rules()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :ssl, :crypto]
    ]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test]},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:usage_rules, "~> 1.0", only: [:dev]}
    ]
  end

  defp usage_rules do
    [
      file: "CLAUDE.md",
      usage_rules: ["usage_rules:all"]
    ]
  end
end
