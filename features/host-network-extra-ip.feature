Feature: Extra IPs on a Linux NIC
  Host interfaces Apply posts /api/system/bridges as address-only.
  Dropping an extra from the form must delete it live, not only persist adds.
  Mac Apply is verified on the Mini by hand. This feature is Linux / Docker.

  Background:
    Given a Linux Device with BarkVisor installed
    And a throwaway dummy NIC that is not the default route

  Scenario: add an extra IP then remove it
    Given the NIC has a primary IPv4
    When I dry-run Apply with DHCP plus extra 10.200.55.50/24
    Then the commands include ip addr add 10.200.55.50/24
    When I Apply and Keep
    Then ip addr shows 10.200.55.50/24 on the NIC
    When I dry-run Apply with DHCP only
    Then the commands include ip addr del 10.200.55.50/24
    And the commands do not include ip addr add 10.200.55.50/24
    When I Apply and Keep
    Then ip addr does not show 10.200.55.50/24
    And the primary IPv4 is still on the NIC

  Scenario: extra-IP auto-revert does not delete a VM network
    Given the NIC has a primary IPv4
    When I Apply extra 10.200.55.50/24 and the Keep window expires
    Then the extra IP is gone
    And no VM network named after the NIC was deleted

  Scenario: Create Bridge auto-revert keeps the bridge if a VM attached during the window
    When I Create Bridge br9
    And a Workload attaches to Bridged (br9) before Keep
    And the Keep window expires
    Then br9 is still present
    And the Workload network still exists
