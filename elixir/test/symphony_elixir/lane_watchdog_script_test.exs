defmodule SymphonyElixir.LaneWatchdogScriptTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, "scripts/lane-watchdog.sh")

  setup do
    tmp_dir = Path.join([@repo_root, "elixir", "tmp", "lane-watchdog-script-#{System.unique_integer([:positive])}"])
    bin_dir = Path.join(tmp_dir, "bin")
    events_file = Path.join(tmp_dir, "events.log")

    File.mkdir_p!(bin_dir)
    write_executable(Path.join(bin_dir, "curl"), curl_stub())
    write_executable(Path.join(bin_dir, "launchctl"), event_stub("launchctl"))
    write_executable(Path.join(bin_dir, "mise"), event_stub("mise"))

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, bin_dir: bin_dir, events_file: events_file}
  end

  test "degraded health is live enough and does not restart the daemon", context do
    body = ~s({"health":{"status":"degraded","degraded_reason":"linear_api_request"},"counts":{"running":0}})

    assert {"", 0} = run_watchdog(body, context)
    refute File.exists?(context.events_file)
  end

  test "only the top-level health status controls restart decisions", context do
    body = ~s({"running":[{"status":"healthy"}],"health":{"status":"stale"}})

    assert {output, 0} = run_watchdog(body, context)
    assert output =~ "lane unhealthy on port 49152"
    assert output =~ "health.status=stale"

    events = File.read!(context.events_file)
    assert events =~ "launchctl kickstart -k gui/"
    assert events =~ "mise exec -- mix ops.file_issue"
    assert events =~ "health.status=stale"
  end

  test "failed probes still restart the daemon with an explicit missing status", context do
    assert {output, 0} = run_watchdog("", context, [{"WATCHDOG_CURL_EXIT", "7"}])
    assert output =~ "health.status=missing"
    assert output =~ "probe_returned_body=false"

    events = File.read!(context.events_file)
    assert events =~ "launchctl kickstart -k gui/"
    assert events =~ "mix ops.file_issue"
  end

  defp run_watchdog(body, context, extra_env \\ []) do
    env =
      [
        {"PATH", context.bin_dir <> ":" <> System.get_env("PATH", "")},
        {"SYMPHONY_LANE_PORT", "49152"},
        {"WATCHDOG_CURL_BODY", body},
        {"WATCHDOG_EVENTS_FILE", context.events_file}
      ] ++ extra_env

    System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp curl_stub do
    """
    #!/usr/bin/env bash
    if [ "${WATCHDOG_CURL_EXIT:-0}" != "0" ]; then
      exit "$WATCHDOG_CURL_EXIT"
    fi
    printf "%s" "$WATCHDOG_CURL_BODY"
    """
  end

  defp event_stub(name) do
    """
    #!/usr/bin/env bash
    printf "#{name} %s\\n" "$*" >> "$WATCHDOG_EVENTS_FILE"
    exit 0
    """
  end
end
