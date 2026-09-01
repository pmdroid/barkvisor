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

  Scenario: Unreadable mounted volume shows a permission error instead of a generic failure
    Given a volume under /Volumes that the daemon is not allowed to read
    When I open that volume in the folder picker
    Then the daemon answers with a typed permission_denied error, not a generic 500
    And the picker shows how to grant Full Disk Access on macOS
    And the picker keeps the current folder listing instead of jumping back to Places
