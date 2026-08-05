defmodule SymphonyElixir.DispatchPauseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.DispatchPause

  setup do
    dir = Path.join(System.tmp_dir!(), "dispatch-pause-test-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "dispatch-paused.json")
    System.put_env("SYMPHONY_DISPATCH_PAUSE_FILE", file)

    on_exit(fn ->
      System.delete_env("SYMPHONY_DISPATCH_PAUSE_FILE")
      File.rm_rf!(dir)
    end)

    %{pause_file: file}
  end

  test "starts unpaused" do
    refute DispatchPause.paused?()
    assert %{paused: false, paused_at: nil} = DispatchPause.status()
  end

  test "pause persists a flag file with a timestamp and resume removes it", %{pause_file: file} do
    assert :ok = DispatchPause.pause()
    assert DispatchPause.paused?()
    assert File.exists?(file)

    assert %{paused: true, paused_at: paused_at} = DispatchPause.status()
    assert {:ok, _dt, _offset} = DateTime.from_iso8601(paused_at)

    assert :ok = DispatchPause.resume()
    refute DispatchPause.paused?()
    refute File.exists?(file)
  end

  test "resume is idempotent when never paused" do
    assert :ok = DispatchPause.resume()
    refute DispatchPause.paused?()
  end

  test "pause survives a corrupt flag file for paused? but degrades status gracefully", %{pause_file: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "not json")

    assert DispatchPause.paused?()
    assert %{paused: true, paused_at: nil} = DispatchPause.status()
  end
end
