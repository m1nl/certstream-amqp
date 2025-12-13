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
      {:easy_ssl, git: "https://github.com/CaliDog/EasySSL.git", branch: "master"},
      {:httpoison, "~> 2.2"},
      {:jason, "~> 1.4"},
      {:number, "~> 1.0"},
      {:pobox, "~> 1.2"},

      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},

      {:amqp, "~> 3.3.0"}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end
end
