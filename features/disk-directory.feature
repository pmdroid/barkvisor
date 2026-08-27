Feature: Per-Device VM disk directory

  Scenario: Settings Disks picks a Device then its disk directory
    Given a Home with more than one Device
    When I open Settings Disks
    Then I can choose which Device's default VM disk directory to edit
    And GET and PUT use that Device's /system/disk/settings path

  Scenario: Folder picker lists places on the selected Device
    Given Settings Disks is open for a reachable Device
    When I click Browse
    Then the picker lists that Device's folder roots
    And an empty disk directory still has a parent that returns to those roots
