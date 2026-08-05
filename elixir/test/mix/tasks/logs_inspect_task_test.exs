defmodule Mix.Tasks.Logs.InspectTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Logs.Inspect, as: LogsInspect

  setup do
    logs_root = Path.join(System.tmp_dir!(), "logs-inspect-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(logs_root, "log/test"))
    on_exit(fn -> File.rm_rf(logs_root) end)
    %{logs_root: logs_root}
  end

  test "defaults to runtime logs", %{logs_root: logs_root} do
    File.write!(Path.join(logs_root, "log/symphony.log.1"), """
    warning: Retrying issue_id=runtime issue_identifier=SYM-104 in 1000ms
    """)

    File.write!(Path.join(logs_root, "log/test/symphony.log.1"), """
    error: Breaker parked issue_id=fixture issue_identifier=SYM-1 after 4 failures
    """)

    output = capture_io(fn -> LogsInspect.run(["--logs-root", logs_root]) end)

    assert output =~ "source=runtime"
    assert output =~ "total_lines=1"
    assert output =~ "retry=1"
    assert output =~ "SYM-104=1"
    refute output =~ "SYM-1=1"
  end

  test "test logs must be selected explicitly", %{logs_root: logs_root} do
    File.write!(Path.join(logs_root, "log/test/symphony.log.1"), """
    error: Breaker parked issue_id=fixture issue_identifier=SYM-1 after 4 failures
    warning: Linear auth failed; retrying request with bootstrap Linear auth issue_identifier=MT-AUTH
    """)

    output = capture_io(fn -> LogsInspect.run(["--logs-root", logs_root, "--source", "test"]) end)

    assert output =~ "source=test"
    assert output =~ "total_lines=2"
    assert output =~ "breaker_or_park=1"
    assert output =~ "linear_auth_401=1"
    assert output =~ "SYM-1=1"
    assert output =~ "MT-AUTH=1"
  end

  test "honors explicit base path and top identifier limit", %{logs_root: logs_root} do
    base_path = Path.join(logs_root, "custom/runtime.log")
    File.mkdir_p!(Path.dirname(base_path))

    File.write!("#{base_path}.1", """
    warning: Retrying issue_id=runtime issue_identifier=AAA-1 in 1000ms
    warning: Retrying issue_id=runtime issue_identifier=AAA-1 in 1000ms
    warning: Retrying issue_id=runtime issue_identifier=BBB-1 in 1000ms
    """)

    output = capture_io(fn -> LogsInspect.run(["--path", base_path, "--top", "1"]) end)

    assert output =~ "base_path=#{base_path}"
    assert output =~ "total_lines=3"
    assert output =~ "AAA-1=2"
    refute output =~ "BBB-1=1"
  end

  test "rejects unknown source values" do
    assert_raise Mix.Error, ~r/invalid --source/, fn ->
      LogsInspect.run(["--source", "all"])
    end
  end

  test "rejects invalid options" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      LogsInspect.run(["--bogus"])
    end
  end
end
