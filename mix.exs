defmodule Mathsolver.MixProject do
  use Mix.Project

  def project do
    [
      app: :mathsolver,
      version: "0.2.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "BYOK AI math solver with execution-based verification (PAL-style) — bring your own OpenAI-compatible API key; the answer is computed locally by executing a model-generated program, never taken from a number the model stated.",
      package: package()
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl]]

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
        "GitHub" => "https://github.com/aiPublicProject/mathsolver-elixir"
      }
    ]
  end
end
