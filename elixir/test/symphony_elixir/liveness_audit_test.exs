defmodule SymphonyElixir.LivenessAuditTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The liveness audit (contract proof 3): every orchestration wait class must
  declare a bound and a default action in the lane's own contract. The five
  wait classes and their bounds:

    1. candidate wait      -> polling.interval_ms
    2. running turn        -> codex.turn_timeout_ms
    3. stalled stream      -> codex.stall_timeout_ms
    4. blocked issue       -> agent.blocked_max_age_ms (default action: retry)
    5. retry loop          -> agent.max_consecutive_failures (default action:
                              park + deduplicated ops issue) with delay capped
                              by agent.max_retry_backoff_ms
  """

  @workflow_path Path.expand("../../WORKFLOW.md", __DIR__)

  defp front_matter! do
    [_, yaml | _] = @workflow_path |> File.read!() |> String.split("---\n", parts: 3)
    YamlElixir.read_from_string!(yaml)
  end

  test "every orchestration wait class is bounded in the lane contract" do
    fm = front_matter!()

    assert is_integer(get_in(fm, ["polling", "interval_ms"])), "candidate wait unbounded"
    assert is_integer(get_in(fm, ["codex", "turn_timeout_ms"])), "running turn unbounded"
    assert is_integer(get_in(fm, ["codex", "stall_timeout_ms"])), "stalled stream unbounded"
    assert is_integer(get_in(fm, ["agent", "blocked_max_age_ms"])), "blocked wait unbounded"
    assert is_integer(get_in(fm, ["agent", "max_consecutive_failures"])), "retry loop unbounded"
  end

  test "the schema accepts and validates the liveness bounds" do
    attrs = %{"max_consecutive_failures" => 5, "blocked_max_age_ms" => 86_400_000}
    changeset = SymphonyElixir.Config.Schema.Agent.changeset(%SymphonyElixir.Config.Schema.Agent{}, attrs)
    assert changeset.valid?

    bad = SymphonyElixir.Config.Schema.Agent.changeset(%SymphonyElixir.Config.Schema.Agent{}, %{"max_consecutive_failures" => 0})
    refute bad.valid?
  end

  test "liveness bounds default to disabled so existing daemons are unchanged" do
    changeset = SymphonyElixir.Config.Schema.Agent.changeset(%SymphonyElixir.Config.Schema.Agent{}, %{})
    agent = Ecto.Changeset.apply_changes(changeset)
    assert agent.max_consecutive_failures == nil
    assert agent.blocked_max_age_ms == nil
  end
end
