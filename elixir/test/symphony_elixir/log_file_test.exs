defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "test configuration writes to a separate test log path" do
    assert Application.fetch_env!(:symphony_elixir, :log_file) ==
             Path.join(File.cwd!(), "log/test/symphony.log")

    refute Application.fetch_env!(:symphony_elixir, :log_file) == LogFile.default_log_file()
  end
end
