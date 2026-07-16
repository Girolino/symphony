defmodule SymphonyElixir.HarnessCheck do
  @moduledoc """
  Enforces REVIEW.md rule RV-B1: the harness stays generic. Scans `lib/` for
  product-specific terms (product names, product hosts) that belong in target
  repositories' `WORKFLOW.md` and repo-owned scripts, never in the harness.

  Exemptions use `file:line` or bare `file` entries, one per line, `#` for
  comments — the same shape as the specs.check exemptions file.
  """

  @default_terms [
    "alpinereach",
    "alpine reach",
    "alpine-reach",
    "dr-thomas",
    "drthomas",
    "content-pipeline",
    "contentpipeline",
    "natuvera"
  ]

  @type finding :: %{file: String.t(), line: pos_integer(), term: String.t(), text: String.t()}

  @spec product_policy_findings([Path.t()], keyword()) :: [finding()]
  def product_policy_findings(paths, opts \\ []) do
    terms = Keyword.get(opts, :terms, @default_terms)
    exemptions = opts |> Keyword.get(:exemptions, []) |> MapSet.new()

    paths
    |> Enum.flat_map(&collect_elixir_files/1)
    |> Enum.flat_map(&file_findings(&1, terms))
    |> Enum.reject(&exempted?(&1, exemptions))
    |> Enum.sort_by(&{&1.file, &1.line, &1.term})
  end

  @spec default_terms() :: [String.t()]
  def default_terms, do: @default_terms

  # This module necessarily contains the forbidden terms (they ARE the term
  # list), so it is skipped by construction rather than by exemption.
  @self_files ["lib/symphony_elixir/harness_check.ex"]

  defp collect_elixir_files(path) do
    cond do
      File.dir?(path) -> path |> Path.join("**/*.{ex,exs}") |> Path.wildcard() |> Enum.reject(&self_file?/1)
      File.regular?(path) -> if self_file?(path), do: [], else: [path]
      true -> []
    end
  end

  defp self_file?(file), do: Enum.any?(@self_files, &String.ends_with?(file, &1))

  defp file_findings(file, terms) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      lowered = String.downcase(text)

      terms
      |> Enum.filter(&String.contains?(lowered, &1))
      |> Enum.map(&%{file: file, line: line, term: &1, text: String.trim(text)})
    end)
  end

  defp exempted?(%{file: file, line: line}, exemptions) do
    MapSet.member?(exemptions, "#{file}:#{line}") or MapSet.member?(exemptions, file)
  end
end
