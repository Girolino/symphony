defmodule SymphonyElixir.CredentialProbeScriptTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, "scripts/credential-probe.sh")

  test "fails primary validation without falling back to bootstrap" do
    probe = probe_env(primary_status: "418", bootstrap_status: "200")

    {output, status} = run_probe(probe)

    assert status == 1
    assert output =~ "LINEAR_API_KEY primary invalid (viewer query returned 418)"
    refute output =~ probe.primary_token
    refute output =~ probe.bootstrap_token
    assert File.read!(probe.trace_file) =~ "linear_key_env=unset"
  end

  test "passes when primary and bootstrap credentials validate" do
    probe = probe_env(primary_status: "200", bootstrap_status: "200")

    {output, status} = run_probe(probe)

    assert status == 0
    assert output =~ "credential probe: all capabilities valid (by name)"
    refute output =~ probe.primary_token
    refute output =~ probe.bootstrap_token
    refute File.exists?(probe.trace_file)
  end

  defp run_probe(probe) do
    System.cmd("bash", [@script],
      cd: @repo_root,
      env: probe.env,
      stderr_to_stdout: true
    )
  end

  defp probe_env(opts) do
    root = Path.join(System.tmp_dir!(), "symphony-credential-probe-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    bin = Path.join(root, "bin")
    bootstrap_dir = Path.join([home, ".config", "linear-codex"])
    trace_file = Path.join(root, "mise-trace.txt")
    primary_token = "primary-token-#{System.unique_integer([:positive])}"
    bootstrap_token = "bootstrap-token-#{System.unique_integer([:positive])}"

    File.mkdir_p!(bootstrap_dir)
    File.mkdir_p!(bin)
    File.write!(Path.join(bootstrap_dir, "env"), "LINEAR_API_KEY=#{bootstrap_token}\n")
    write_executable!(Path.join(bin, "curl"), fake_curl())
    write_executable!(Path.join(bin, "gh"), fake_gh())
    write_executable!(Path.join(bin, "mise"), fake_mise())

    on_exit(fn -> File.rm_rf(root) end)

    %{
      primary_token: primary_token,
      bootstrap_token: bootstrap_token,
      trace_file: trace_file,
      env: [
        {"HOME", home},
        {"PATH", bin <> ":" <> System.get_env("PATH", "")},
        {"LINEAR_API_KEY", primary_token},
        {"PRIMARY_TOKEN", primary_token},
        {"BOOTSTRAP_TOKEN", bootstrap_token},
        {"PRIMARY_STATUS", Keyword.fetch!(opts, :primary_status)},
        {"BOOTSTRAP_STATUS", Keyword.fetch!(opts, :bootstrap_status)},
        {"TRACE_FILE", trace_file}
      ]
    }
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp fake_curl do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    header=""
    for arg in "$@"; do
      case "$arg" in
        @*) header="${arg#@}" ;;
      esac
    done

    if [ -n "$header" ] && grep -q "$PRIMARY_TOKEN" "$header"; then
      printf '%s' "$PRIMARY_STATUS"
    elif [ -n "$header" ] && grep -q "$BOOTSTRAP_TOKEN" "$header"; then
      printf '%s' "$BOOTSTRAP_STATUS"
    else
      printf '401'
    fi
    """
  end

  defp fake_gh do
    """
    #!/usr/bin/env bash
    if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
      exit 0
    fi
    if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
      printf '0'
      exit 0
    fi
    exit 0
    """
  end

  defp fake_mise do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${LINEAR_API_KEY:-}" ]; then
      printf 'linear_key_env=unset\\n' > "$TRACE_FILE"
    else
      printf 'linear_key_env=set\\n' > "$TRACE_FILE"
    fi
    exit 0
    """
  end
end
