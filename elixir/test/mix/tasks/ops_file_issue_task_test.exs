defmodule Mix.Tasks.Ops.FileIssueTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ops.FileIssue

  defmodule CreatedFiler do
    @spec file(String.t(), String.t(), keyword()) :: {:created, map()}
    def file(title, body, opts) do
      send(self(), {:filed, title, body, opts})
      {:created, %{"identifier" => "SYME2E-42", "url" => "https://linear.app/x"}}
    end
  end

  defmodule ExistingFiler do
    @spec file(String.t(), String.t(), keyword()) :: {:existing, map()}
    def file(_title, _body, _opts) do
      {:existing, %{"identifier" => "SYME2E-7", "url" => "https://linear.app/y"}}
    end
  end

  defmodule ErrorFiler do
    @spec file(String.t(), String.t(), keyword()) :: {:error, term()}
    def file(_title, _body, _opts), do: {:error, :nope}
  end

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :ops_issue_filer) end)
    :ok
  end

  test "creates an issue from an inline body" do
    Application.put_env(:symphony_elixir, :ops_issue_filer, CreatedFiler)

    output =
      capture_io(fn ->
        FileIssue.run(["--title", "promote FAIL", "--body", "details"])
      end)

    assert output =~ "created SYME2E-42"
    assert_received {:filed, "promote FAIL", "details", _opts}
  end

  test "reads the body from a file and reports existing issues" do
    Application.put_env(:symphony_elixir, :ops_issue_filer, ExistingFiler)

    body_file = Path.join(System.tmp_dir!(), "ops-issue-body-#{System.unique_integer([:positive])}.txt")
    File.write!(body_file, "report contents")
    on_exit(fn -> File.rm(body_file) end)

    output =
      capture_io(fn ->
        FileIssue.run(["--title", "promote FAIL", "--body-file", body_file])
      end)

    assert output =~ "found existing SYME2E-7"
  end

  test "exits non-zero when filing fails" do
    Application.put_env(:symphony_elixir, :ops_issue_filer, ErrorFiler)

    output =
      capture_io(:stderr, fn ->
        assert catch_exit(FileIssue.run(["--title", "t", "--body", "b"])) ==
                 {:shutdown, 1}
      end)

    assert output =~ "ops.file_issue failed"
  end

  test "requires title and body" do
    assert_raise Mix.Error, ~r/--title is required/, fn ->
      FileIssue.run(["--body", "b"])
    end

    assert_raise Mix.Error, ~r/--body or --body-file/, fn ->
      FileIssue.run(["--title", "t"])
    end
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      FileIssue.run(["--bogus"])
    end
  end
end
