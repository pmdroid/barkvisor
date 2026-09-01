Feature: Per-Device VM disk directory

  Scenario: Device page edits that Device's disk directory
    Given a Home with more than one Device
    When I open a Device
    Then I can edit that Device's default VM disk directory
    And GET and PUT use that Device's /system/disk/settings path
    And Settings has no Disks tab
    And /settings?tab=disks redirects to Devices
    And Reset to default stays disabled until that Device's disk settings have loaded
    And switching Device clears the previous Device's disk settings before GET

  Scenario: Folder picker lists places on the selected Device
    Given a Device page is open for a reachable Device
    When I click Browse
    Then the picker lists that Device's folder roots
    And an empty disk directory still has a parent that returns to those roots

  Scenario: Unreadable mounted volume shows a permission error instead of a generic failure
    Given a volume under /Volumes that the daemon is not allowed to read
    When I open that volume in the folder picker
    Then the daemon answers with a typed permission_denied error, not a generic 500
    And the picker shows how to grant Full Disk Access on macOS
    And the picker keeps the current folder listing instead of jumping back to Places

  Scenario: Mac Data volume is an allowed folder
    Given the folder picker is open on a Mac
    When I browse /Volumes/Data
    Then that path is allowed even if it firmlinks to /System/Volumes/Data
    And a permission failure is typed, never a generic 500
