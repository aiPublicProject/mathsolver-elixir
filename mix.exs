defmodule Mathsolver.MixProject do
  use Mix.Project

  def project do
    [
      app: :mathsolver,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "BYOK AI math solver with independent verification — bring your own OpenAI-compatible API key, answers verified by local expression evaluation.",
      package: package()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Homepage" => "https://mathsolver.help",
        "GitHub" => "https://github.com/mathsolver-help/mathsolver-elixir"
      }
    ]
  end
end
