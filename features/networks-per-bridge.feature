Feature: Per-bridge host network apply
  Host-bridge mutate is keyed by request.bridge. Keep, Revert, ACL, netplan,
  pending, and owner markers never imply a shared br0.

  Scenario: br1 files ACL and pending are not br0
    Given a Linux Device with foreign br0
    When apply runs with bridge br1
    Then netplan is 90-barkvisor-br1.yaml
    And ACL is tagged barkvisor:allow-br1
    And pending is /run/barkvisor/br1-pending.json
    And the owner marker is host-bridge-br1.json with uplink and createdBridge

  Scenario: createdBridge is about this brN
    Given facts.bridges already lists br0
    When apply creates br1
    Then createdBridge is true
    And createdBridge is not facts.bridges.isEmpty

  Scenario: name collision is 409
    Given br0 already exists and is not owned
    When apply targets br0
    Then the server returns 409

  Scenario: next-free skips sysfs and markers
    Given br0 exists in sysfs and br1 has an owner marker
    Then next-free is br2

  Scenario: one pending commit per Device
    Given a pending apply for br0
    When apply starts for br1
    Then the server returns 409 until Keep or Revert

  Scenario: SPA Keep and DELETE use pending.target
    Given pending.target is br1
    Then Keep posts bridge br1
    And DELETE uses /br1 not /br0
    And Keep banner matches the uplink or br1

  Scenario: owned delete unenslaves and removes the kernel bridge
    Given marker createdBridge is true for br1
    And no Workload references br1
    When POST action delete targets br1
    Then the plan unenslaves the uplink
    And restores NIC L3
    And runs ip link del br1
    And Keep is required within 30s

  Scenario: foreign revert never deletes the kernel bridge
    Given marker createdBridge is false for br0
    When action revert targets br0
    Then tagged files are stripped
    And the plan never contains ip link del

  Scenario: delete is blocked when a Workload still uses the bridge
    Given marker createdBridge is true for br1
    And a Workload is attached to br1
    When POST action delete targets br1
    Then the server returns 409

  Scenario: UI Delete vs Revert follows the marker
    Given createdBridge is true
    Then the drawer shows Delete not Revert
    Given createdBridge is false
    Then the drawer shows Revert not Delete
