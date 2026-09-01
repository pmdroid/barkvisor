Feature: Device IPs live on the Bridge row
  L3 (DHCP, aliases, gateway, DNS) is edited on brN. An enslaved NIC is L2-only.

  Scenario: Bridge row owns addresses
    Given a Linux or Mac Device with br0 enslaving the uplink
    Then the br0 drawer can edit DHCP, aliases, gateway, and DNS
    And Apply sends bridge br0 and nic from the enslaved member

  Scenario: enslaved NIC is L2-only
    Given eth0 is enslaved to br0
    Then the eth0 drawer cannot edit addresses
    And the addresses column for eth0 is em dash

  Scenario: Mac apply writes the uplink when the map exists
    Given Mac synthetic br0 maps to en0
    Then the UI shows IPs on br0
    And Apply writes interface en0 with bridge br0
