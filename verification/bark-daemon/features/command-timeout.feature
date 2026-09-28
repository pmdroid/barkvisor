Feature: Command timeouts finish

  Scenario: a noisy child cannot hold the test process open
    When the command timeout regression runs
    Then the command timeout regression passes
