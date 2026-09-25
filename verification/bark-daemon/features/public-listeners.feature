Feature: BarkServer owns the public listeners

  Scenario: an authorized mutation is checked again inside BarkDaemon
    When the public listener suite runs
    Then the public listener suite passes
