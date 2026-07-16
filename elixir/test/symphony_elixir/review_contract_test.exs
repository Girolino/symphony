defmodule SymphonyElixir.ReviewContractTest do
  use ExUnit.Case, async: true

  @workflow_path Path.expand("../../WORKFLOW.md", __DIR__)
  @review_path Path.expand("../../../REVIEW.md", __DIR__)

  defp front_matter! do
    contents = File.read!(@workflow_path)
    [_, yaml | _] = String.split(contents, "---\n", parts: 3)
    YamlElixir.read_from_string!(yaml)
  end

  test "the review lane states are dispatchable active states" do
    active = get_in(front_matter!(), ["tracker", "active_states"])

    for state <- ["Todo", "In Progress", "Agent Review", "Arbiter", "Merging", "Rework"] do
      assert state in active, "expected #{state} in active_states"
    end
  end

  test "every review rule cited in WORKFLOW.md exists in REVIEW.md" do
    workflow = File.read!(@workflow_path)
    review = File.read!(@review_path)

    cited =
      ~r/RV-[A-Z]+\d+/
      |> Regex.scan(workflow)
      |> List.flatten()
      |> Enum.uniq()

    for rule <- cited do
      assert review =~ rule, "WORKFLOW.md cites #{rule} but REVIEW.md does not define it"
    end
  end

  test "no human escalation path remains in the lane contract" do
    workflow = File.read!(@workflow_path)
    refute workflow =~ "Human Review"
    assert workflow =~ "Arbiter"
    assert workflow =~ "decision is\nFINAL" or workflow =~ "decision is FINAL" or workflow =~ "FINAL"
    assert workflow =~ "Deferred"
  end

  test "REVIEW.md defines the bounded-rounds and no-rejection-without-a-rule policies" do
    review = File.read!(@review_path)
    assert review =~ "RV-P1"
    assert review =~ "no-rejection-without-a-rule"
    assert review =~ "arbiter"
  end

  test "role boundaries are enforced by the harness, not just the prompt" do
    fm = front_matter!()
    boundaries = get_in(fm, ["agent", "role_boundary_states"])
    assert "Agent Review" in boundaries
    assert "Arbiter" in boundaries
  end
end
