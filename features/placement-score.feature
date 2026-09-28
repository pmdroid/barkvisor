Feature: Score placement from one fresh health report

  @bdd-score-reuses-health-report
  Scenario: A second placement score inside five seconds does not probe again
    Given a Home health report was collected less than five seconds ago
    When the client posts two placement scores inside that window
    Then members are probed once and both responses rank from that report

  @bdd-score-budget-bounds-dead-member
  Scenario: A member that never answers cannot hold placement scoring past the budget
    Given one member accepts no mTLS connection and the others answer
    When the client posts a placement score and no fresh health report exists
    Then the handler returns by the 2.5 second probe budget and that member is ineligible

  @bdd-score-skips-recorded-timeout
  Scenario: A recorded connect timeout is not probed again immediately
    Given the previous probe recorded connectTimeout for a member
    When another placement score runs before the reachability refresh
    Then the handler does not open a hop to that member
