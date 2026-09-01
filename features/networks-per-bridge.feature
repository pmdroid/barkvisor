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
