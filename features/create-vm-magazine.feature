Feature: Create VM magazine wizard

  Scenario: Gallery cards do not show architecture labels
    Given the Create VM dialog is open on step 1
    Then template cards should not display arm64 or x86_64 badges

  Scenario: Cloud-init guests show hostname hint on step 2
    Given the Create VM dialog is open with a cloud-init template selected
    When I am on step 2
    Then I should see a hostname hint under the name field

  Scenario: Windows and ISO guests do not show hostname hint
    Given the Create VM dialog is open with Windows selected
    When I am on step 2
    Then I should not see a hostname hint under the name field

  Scenario: Host buffer rejects allocating all host cores
    Given a Device with 10 logical CPUs
    When I try to create a VM with 10 cores
    Then validation should reject the request

  Scenario: Raw host disk option is dimmed on macOS Devices
    Given the Create VM dialog is on step 3
    And the picked Device runs macOS
    Then the raw host device card should be disabled
