Feature: Workload configuration, observation, and health stay separate
  Requested settings, the generation the runtime applied, and health are different facts.

  Scenario: older writes cannot replace a newer configuration or deployed generation
    When the workload fact tests run
    Then those tests pass

  Scenario: Docker health uses service observations and QEMU checks stay on virtual machines
    When the workload fact tests run
    Then those tests pass

  Scenario: accepted CPU and memory are enforced or rejected before acceptance
    When the workload fact tests run
    Then those tests pass

  Scenario: stored workloads keep their fields and a public cache cannot overwrite them
    When the workload fact tests run
    Then those tests pass
