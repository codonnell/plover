defmodule Plover.MixProject do
  use Mix.Project

  def project do
    [
      app: :plover,
      version: "0.2.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ssl]],
      usage_rules: usage_rules(),
      package: package(),
      source_url: "https://github.com/codonnell/plover",
      homepage_url: "https://github.com/codonnell/plover",
      docs: docs()
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
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ex_doc, "~> 0.37", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Plover provides a high-level API for connecting to IMAP servers over implicit TLS, authenticating, managing mailboxes, and fetching/searching/storing messages."
  end

  defp usage_rules do
    [
      file: "CLAUDE.md",
      usage_rules: ["usage_rules:all"]
    ]
  end

  defp docs do
    [
      extras: ["guides/email-content.md", "guides/testing.md"],
      groups_for_extras: [Guides: ~r/guides\/.*/]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/codonnell/plover"},
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* usage-rules.md)
    ]
  end
end
