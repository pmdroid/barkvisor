Feature: One owner sequences Workload operations
  API, Home, startup, and background work share one Device owner.
  Each Workload has its own queue. QEMU and Docker stay in their modules.

  Scenario: a suspended operation blocks a second mutation of the same Workload
    Then the coordinator test "suspended operation blocks a second mutation of the same Workload" passed

  Scenario: different Workloads progress while another is suspended
    Then the coordinator test "different Workloads run while another is suspended" passed

  Scenario: a retry does not run an accepted mutation twice
    Then the coordinator test "retry of an accepted operation does not run the mutation twice" passed

  Scenario: cancellation releases the lane only after the body settles
    Then the coordinator test "cancellation releases the lane only after the body settles" passed

  Scenario: reconciliation cannot overwrite a newer generation
    Then the coordinator test "reconciliation cannot overwrite a newer generation or a finished operation" passed

  Scenario: one Device has one operation owner
    Then the coordinator test "one Device constructs a single operation owner" passed

  Scenario: runtime handles keep the complete Workload id
    Then the coordinator test "runtime handle and sockets keep the complete Workload id" passed
