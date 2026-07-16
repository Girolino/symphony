defmodule Mix.Tasks.Harness.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Harness.Check
  alias SymphonyElixir.HarnessCheck

  setup do
    dir = Path.join(System.tmp_dir!(), "harness-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "passes on generic code", %{dir: dir} do
    File.write!(Path.join(dir, "clean.ex"), "defmodule Clean do\n  def run, do: :ok\nend\n")

    output = capture_io(fn -> Check.run(["--paths", dir]) end)
    assert output =~ "no product-specific policy"
  end

  test "fails on seeded product terms with file and line", %{dir: dir} do
    File.write!(Path.join(dir, "dirty.ex"), "# routes Alpine Reach traffic\ndefmodule Dirty do\nend\n")

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/1 product-policy finding/, fn ->
          Check.run(["--paths", dir])
        end
      end)

    assert output =~ "dirty.ex:1"
    assert output =~ "alpine"
  end

  test "honors file:line and whole-file exemptions", %{dir: dir} do
    file = Path.join(dir, "legacy.ex")
    File.write!(file, "# dr-thomas control script docs pointer\n")

    exemptions = Path.join(dir, "exempt.txt")
    File.write!(exemptions, "# comment\n#{file}:1\n")

    output = capture_io(fn -> Check.run(["--paths", dir, "--exemptions-file", exemptions]) end)
    assert output =~ "no product-specific policy"

    File.write!(exemptions, "#{file}\n")
    output = capture_io(fn -> Check.run(["--paths", dir, "--exemptions-file", exemptions]) end)
    assert output =~ "no product-specific policy"
  end

  test "missing exemptions file is treated as empty", %{dir: dir} do
    File.write!(Path.join(dir, "clean.ex"), ":ok\n")

    output = capture_io(fn -> Check.run(["--paths", dir, "--exemptions-file", "/nonexistent"]) end)
    assert output =~ "no product-specific policy"
  end

  test "pure module detects multiple terms per line, including overlaps", %{dir: dir} do
    file = Path.join(dir, "multi.ex")
    File.write!(file, "# contentpipeline and natuvera both here\n# alpinereach later\n")

    findings = HarnessCheck.product_policy_findings([dir])
    terms = Enum.map(findings, & &1.term)

    assert "contentpipeline" in terms
    assert "natuvera" in terms
    assert "alpinereach" in terms
    assert Enum.all?(findings, &(&1.file == file))
  end

  test "the real harness lib is currently clean" do
    assert HarnessCheck.product_policy_findings(["lib"]) == []
  end

  test "covers default_terms, single-file scan, and missing paths" do
    assert "alpinereach" in HarnessCheck.default_terms()
    # Bare "alpine" is deliberately NOT a term: Alpine Linux references are
    # legitimate in a generic harness (review round-3 CR-004).
    refute "alpine" in HarnessCheck.default_terms()

    # Scanning the checker's own file yields nothing (skipped by construction).
    assert HarnessCheck.product_policy_findings(["lib/symphony_elixir/harness_check.ex"]) == []

    # A direct single-file path is scanned; a missing path is ignored.
    dir = Path.join(System.tmp_dir!(), "harness-single-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    file = Path.join(dir, "one.ex")
    File.write!(file, "# natuvera\n")

    assert [%{term: "natuvera"}] = HarnessCheck.product_policy_findings([file])
    assert HarnessCheck.product_policy_findings(["/nonexistent/path"]) == []
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Check.run(["--bogus"])
    end
  end
end
