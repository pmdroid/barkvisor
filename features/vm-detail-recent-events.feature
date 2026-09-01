Feature: Workload details has no Recent events
  VM details used to show a Recent events sheet. That sheet is not a product feature.

  Scenario: Overview has no Recent events sheet
    Given I open a Workload details page
    Then the Overview tab does not show a Recent events sheet
    And the client does not fetch /api/vms/{id}/events for that sheet

  Scenario: Console Workload details has no Recent events
    Given I open a Workload in Console
    Then there is no Recent events section
