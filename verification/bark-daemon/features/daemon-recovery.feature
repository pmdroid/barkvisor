Feature: BarkDaemon recovers accepted work
  Scenario: restart adoption, server-down rollback, and a rejected protocol version
    When the daemon recovery suite runs
    Then the daemon recovery suite passes
