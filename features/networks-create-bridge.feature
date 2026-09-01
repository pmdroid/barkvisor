Feature: Create Bridge on Host interfaces
  Create → Bridge is the only path for a new switch. The server allocates
  the next-free brN. One unused NIC is the port. Linux refuses Wi-Fi.
  Apply uses the same confirm and 30s Keep as host-network apply.

  Scenario: next-free name is read-only
    Given facts.bridges already lists br0
    When Create Bridge opens
    Then the name is br1 and cannot be edited

  Scenario: one unused NIC as port
    Given eth0 is enslaved to br0 and eth1 is free
    Then the port list is eth1

  Scenario: Linux refuses Wi-Fi
    Given the Device is Linux
    Then wlan0 is not offered as a port

  Scenario: Mac may use en0
    Given the Device is macOS
    Then en0 is offered as a port
    And Apply sends bridge and nic

  Scenario: VM network checkbox default on
    When Create Bridge Apply succeeds with the checkbox on
    Then a bridged Workload network is created with network.bridge equal to brN

  Scenario: VM network unchecked
    When Create Bridge Apply succeeds with the checkbox off
    Then no Workload network is created

  Scenario: confirm and Keep
    When Create Bridge Apply targets the SSH or SPA port
    Then the same confirm dialog and 30s Keep apply
