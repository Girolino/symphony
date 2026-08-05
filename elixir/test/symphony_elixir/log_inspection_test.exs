defmodule SymphonyElixir.LogInspectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogInspection

  setup do
    logs_root = Path.join(System.tmp_dir!(), "log-inspection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(logs_root, "log/test"))
    on_exit(fn -> File.rm_rf(logs_root) end)
    %{logs_root: logs_root}
  end

  test "runtime source ignores test fixture logs", %{logs_root: logs_root} do
    File.write!(Path.join(logs_root, "log/symphony.log.1"), """
    info: Starting agent run issue_id=runtime issue_identifier=SYM-104
    warning: Retrying issue_id=runtime issue_identifier=SYM-104 in 1000ms
    """)

    File.write!(Path.join(logs_root, "log/test/symphony.log.1"), """
    error: Breaker parked issue_id=fixture issue_identifier=SYM-1 after 4 failures
    warning: Linear auth failed; retrying request with bootstrap Linear auth issue_identifier=MT-AUTH
    """)

    File.write!(Path.join(logs_root, "log/symphony.log.idx"), "ignored index")

    summary = LogInspection.summarize(:runtime, logs_root: logs_root)

    assert summary.files == [Path.join(logs_root, "log/symphony.log.1")]
    assert summary.total_lines == 2
    assert summary.patterns.warnings == 1
    assert summary.patterns.retry == 1
    assert summary.patterns.breaker_or_park == 0
    assert summary.patterns.linear_auth_401 == 0
    assert summary.identifiers == [{"SYM-104", 2}]
  end

  test "test source is explicit and summarizes fixture logs", %{logs_root: logs_root} do
    File.write!(Path.join(logs_root, "log/symphony.log.1"), """
    warning: Retrying issue_id=runtime issue_identifier=SYM-104 in 1000ms
    """)

    File.write!(Path.join(logs_root, "log/test/symphony.log.1"), """
    error: Breaker parked issue_id=fixture issue_identifier=SYM-1 after 4 failures
    warning: Linear auth failed; retrying request with bootstrap Linear auth issue_identifier=MT-AUTH
    warning: Issue stalled: issue_id=fixture issue_identifier=MT-STALL elapsed_ms=5101
    """)

    summary = LogInspection.summarize(:test, logs_root: logs_root)

    assert summary.files == [Path.join(logs_root, "log/test/symphony.log.1")]
    assert summary.total_lines == 3
    assert summary.patterns.errors == 1
    assert summary.patterns.warnings == 2
    assert summary.patterns.retry == 1
    assert summary.patterns.breaker_or_park == 1
    assert summary.patterns.stall == 1
    assert summary.patterns.linear_auth_401 == 1
    assert {"SYM-1", 1} in summary.identifiers
    assert {"MT-AUTH", 1} in summary.identifiers
    assert {"MT-STALL", 1} in summary.identifiers
  end

  test "missing log files return an empty summary", %{logs_root: logs_root} do
    summary = LogInspection.summarize(:runtime, logs_root: Path.join(logs_root, "missing"))

    assert summary.files == []
    assert summary.total_lines == 0

    assert summary.patterns == %{
             errors: 0,
             warnings: 0,
             retry: 0,
             breaker_or_park: 0,
             stall: 0,
             linear_auth_401: 0
           }

    assert summary.identifiers == []
  end
end
