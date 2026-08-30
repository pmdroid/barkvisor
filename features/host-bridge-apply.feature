Feature: Host-bridge Apply and Revert
  Networks Bridge setup applies a Device address on Linux and macOS the same way.
  POST /api/system/bridges applies. DELETE /api/system/bridges/:interface reverts.
  The old socket_vmnet Setup/Start/Stop controller path is gone.

  Scenario: POST applies and DELETE reverts
    Given this Device can mutate host networking
    When I POST /api/system/bridges with action apply and addressing dhcp or static
    Then Linux routes to linuxApply and macOS routes to macHostApply
    And I DELETE /api/system/bridges/:interface to revert
    And start and stop return that host bridges use apply and revert

  Scenario: SystemBridgeController has no socketVmnetApply
    Given Sources/BarkVisor/Server/Controllers/System/SystemBridgeController.swift
    Then the file does not contain socketVmnetApply or parseSocketAction
    And POST and DELETE call linuxApply or macHostApply only
