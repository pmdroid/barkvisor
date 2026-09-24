Feature: BarkDaemon socket workload operations

  Scenario: a repeated operation id does not run the workload twice
    When the socket operation suite runs
    Then the socket operation suite passes
