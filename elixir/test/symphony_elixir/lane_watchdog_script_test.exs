defmodule SymphonyElixir.LaneWatchdogScriptTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, "scripts/lane-watchdog.sh")

  setup do
    tmp_root = Path.join([@repo_root, "elixir", "tmp"])
    tmp_suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(tmp_root, "lane-watchdog-script-#{tmp_suffix}")
    bin_dir = Path.join(tmp_dir, "bin")
    events_file = Path.join(tmp_dir, "events.log")
    curl_count_file = Path.join(tmp_dir, "curl-count")

    File.mkdir_p!(tmp_root)
    File.mkdir!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(bin_dir)
    write_executable(Path.join(bin_dir, "curl"), curl_stub())
    write_executable(Path.join(bin_dir, "launchctl"), event_stub("launchctl"))
    write_executable(Path.join(bin_dir, "mise"), mise_stub())

    {:ok, bin_dir: bin_dir, events_file: events_file, curl_count_file: curl_count_file}
  end

  test "degraded health is live enough and does not restart the daemon", context do
    body = ~s({"health":{"status":"degraded","degraded_reason":"linear_api_request"},"counts":{"running":0}})

    assert {"", 0} = run_watchdog(body, context)
    refute File.exists?(context.events_file)
  end

  test "only the top-level health status controls restart decisions", context do
    body = ~s({"running":[{"status":"healthy"}],"health":{"status":"stale"}})

    assert {output, 0} =
             run_watchdog(body, context, [
               {"WATCHDOG_CURL_READBACK_BODY", ~s({"health":{"status":"healthy"}})}
             ])

    assert output =~ "lane unhealthy on port 49152"
    assert output =~ "health.status=stale"
    assert output =~ "lane restart verified on port 49152"

    events = File.read!(context.events_file)
    assert events =~ "launchctl kickstart -k gui/"
    assert events =~ "mise exec -- mix ops.file_issue"
    assert events =~ "health.status=stale"
    assert events =~ "was restarted by the watchdog"
  end

  test "malformed health payloads with healthy text still restart the daemon", context do
    body = ~s({"health":{"status":"healthy")

    assert {output, 0} =
             run_watchdog(body, context, [
               {"WATCHDOG_CURL_READBACK_BODY", ~s({"health":{"status":"healthy"}})}
             ])

    assert output =~ "health.status=missing"
    assert output =~ "lane restart verified on port 49152"

    events = File.read!(context.events_file)
    assert events =~ "launchctl kickstart -k gui/"
    assert events =~ "mix ops.file_issue"
  end

  test "failed probes still restart the daemon with an explicit missing status", context do
    assert {output, 0} =
             run_watchdog("", context, [
               {"WATCHDOG_CURL_EXIT", "7"},
               {"WATCHDOG_CURL_READBACK_BODY", ~s({"health":{"status":"healthy"}})}
             ])

    assert output =~ "health.status=missing"
    assert output =~ "probe_returned_body=false"
    assert output =~ "lane restart verified on port 49152"

    events = File.read!(context.events_file)
    assert events =~ "launchctl kickstart -k gui/"
    assert events =~ "mix ops.file_issue"
  end

  test "failed kickstarts report an attempted restart without claiming recovery", context do
    body = ~s({"health":{"status":"stale"}})

    assert {output, 0} = run_watchdog(body, context, [{"WATCHDOG_LAUNCHCTL_EXIT", "113"}])

    assert output =~ "lane restart failed on port 49152 (launchctl_exit=113)"

    events = File.read!(context.events_file)
    assert events =~ "--title watchdog failed to restart the symphony lane daemon"
    assert events =~ "launchctl exited 113"
    refute events =~ "was restarted by the watchdog"
  end

  defp run_watchdog(body, context, extra_env \\ []) do
    real_elixir = System.find_executable("elixir") || raise "elixir executable not found"

    env =
      [
        {"PATH", context.bin_dir <> ":" <> System.get_env("PATH", "")},
        {"SYMPHONY_LANE_PORT", "49152"},
        {"SYMPHONY_WATCHDOG_READBACK_ATTEMPTS", "1"},
        {"SYMPHONY_WATCHDOG_READBACK_SLEEP_SECONDS", "0"},
        {"WATCHDOG_CURL_BODY", body},
        {"WATCHDOG_CURL_COUNT_FILE", context.curl_count_file},
        {"WATCHDOG_EVENTS_FILE", context.events_file},
        {"WATCHDOG_LAUNCHCTL_EXIT", "0"},
        {"WATCHDOG_REAL_ELIXIR", real_elixir}
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
    count=0
    if [ -f "$WATCHDOG_CURL_COUNT_FILE" ]; then
      count="$(cat "$WATCHDOG_CURL_COUNT_FILE")"
    fi
    count=$((count + 1))
    printf '%s' "$count" > "$WATCHDOG_CURL_COUNT_FILE"

    if [ "$count" -eq 1 ]; then
      if [ "${WATCHDOG_CURL_EXIT:-0}" != "0" ]; then
        exit "$WATCHDOG_CURL_EXIT"
      fi
      printf "%s" "$WATCHDOG_CURL_BODY"
      exit 0
    fi

    if [ "${WATCHDOG_CURL_READBACK_EXIT:-0}" != "0" ]; then
      exit "$WATCHDOG_CURL_READBACK_EXIT"
    fi

    printf "%s" "${WATCHDOG_CURL_READBACK_BODY:-$WATCHDOG_CURL_BODY}"
    """
  end

  defp mise_stub do
    """
    #!/usr/bin/env bash
    if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--" ] && [ "${3:-}" = "elixir" ]; then
      shift 3
      "$WATCHDOG_REAL_ELIXIR" "$@"
      exit $?
    fi
    printf "mise %s\\n" "$*" >> "$WATCHDOG_EVENTS_FILE"
    exit 0
    """
  end

  defp event_stub(name) do
    """
    #!/usr/bin/env bash
    printf "#{name} %s\\n" "$*" >> "$WATCHDOG_EVENTS_FILE"
    if [ "#{name}" = "launchctl" ]; then
      exit "${WATCHDOG_LAUNCHCTL_EXIT:-0}"
    fi
    exit 0
    """
  end
end
