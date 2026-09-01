Feature: Mac synthetic brN maps to socket_vmnet uplink
  Same words as Linux: the table shows brN. Guts stay socket_vmnet on the uplink.

  Scenario: persist brN to uplink
    When Mac apply commits for bridge br0 on uplink en0
    Then host-bridge-br0.json has uplink en0 and createdBridge

  Scenario: interfaces and readiness show synthetic brN
    Given a marker br0 → en0
    Then readiness.bridges lists br0 enslaved to en0
    And the Host interfaces row for br0 shows L3 from en0
    And L3 is still applied on en0

  Scenario: requireBridgedInterface uses the marker
    Given a marker br0 → en0
    Then requireBridgedInterface br0 succeeds on Mac without a kernel br0

  Scenario: QEMU maps brN to socket_vmnet
    Given a marker br0 → en0
    And socket_vmnet.bridged.en0 exists
    When a Workload starts with Network.bridge br0
    Then QEMU uses socket_vmnet.bridged.en0

  Scenario: VM picker lists brN
    Given a marker br0 → en0
    Then the Workload network picker lists br0
    And the picker does not list raw en0

  Scenario: existing en0 still starts
    Given Network.bridge is en0
    And socket_vmnet.bridged.en0 exists
    When the Workload starts
    Then QEMU uses socket_vmnet.bridged.en0
