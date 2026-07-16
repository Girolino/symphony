defmodule Mix.Tasks.Harness.Check do
  use Mix.Task

  alias SymphonyElixir.HarnessCheck

  @moduledoc """
  Fails when product-specific policy leaks into the generic harness
  (REVIEW.md rule RV-B1).

      mix harness.check [--paths lib] [--exemptions-file path]
  """
  @shortdoc "Fails when product-specific policy appears in lib/"

  @switches [paths: :keep, exemptions_file: :string]
  @default_paths ["lib"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    paths = Keyword.get_values(opts, :paths)
    scanned_paths = if paths == [], do: @default_paths, else: paths

    exemptions =
      case Keyword.get(opts, :exemptions_file) do
        nil -> []
        path -> load_exemptions(path)
      end

    findings = HarnessCheck.product_policy_findings(scanned_paths, exemptions: exemptions)

    if findings == [] do
      Mix.shell().info("harness.check: no product-specific policy in the harness")
      :ok
    else
      Enum.each(findings, fn finding ->
        Mix.shell().error("#{finding.file}:#{finding.line} product term #{inspect(finding.term)}: #{finding.text}")
      end)

      Mix.raise("harness.check failed with #{length(findings)} product-policy finding(s) — see REVIEW.md RV-B1")
    end
  end

  defp load_exemptions(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    else
      []
    end
  end
end
