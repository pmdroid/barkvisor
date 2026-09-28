Feature: macOS package installs BarkDaemon and BarkServer
  Scenario: handoff retires the combined job and records a failed restart
    When the package handoff suite runs
    Then the package handoff suite passes
