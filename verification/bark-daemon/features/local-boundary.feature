Feature: BarkDaemon local management boundary

  Scenario: forged callers and lost replies stay inside BarkDaemon
    When the local management boundary suite runs
    Then the boundary suite passes
