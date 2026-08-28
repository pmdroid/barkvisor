Feature: Settings Repositories per-Device catalog status
  Settings Repositories is a Home view of every Device's catalog sync,
  not only This Device's /repositories.

  Scenario: built-in row shows each Device
    Given a Home with a reachable member
    When I open Settings Repositories
    Then each built-in catalog row shows sync state and lastError per Device
    And a member failure is visible without opening Create VM

  Scenario: Sync fans out through the member proxy
    Given a built-in catalog exists on Home and on a member
    When I click Sync
    Then Home POST /api/repositories/:id/sync
    And the member is POSTed /api/home/devices/:id/v1/repositories/:id/sync

  Scenario: copy is not Home-only
    When I open Settings Repositories
    Then the intro does not say only this Home syncs

  Scenario: members have no Repositories UI
    Then Settings Repositories stays on Home Settings
    And there is no member-facing Repositories page
