# The gate runs under load (auto-promote, CI); timing-tight assert_receive
# calls flaked and made the gate non-deterministic (the class the lane filed
# as SYM-17). A generous global default hardens every bare assert_receive;
# a higher timeout only slows genuinely-failing assertions, never passing ones.
ExUnit.start(assert_receive_timeout: 2_000)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
