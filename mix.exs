defmodule Certstream.Mixfile do
  use Mix.Project

  def project do
    [
      app: :certstream_amqp,
      version: "1.6.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Certstream, []},
    ]
  end

  defp deps do
    [
      {:easy_ssl, "~> 1.3"},
      {:httpoison, "~> 1.8"},
      {:jason, "~> 1.3"},
      {:number, "~> 1.0"},
      {:pobox, "~> 1.2"},

      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.14", only: :test},

      {:amqp, "~> 3.1.1"}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end
end
