Feature: Attach ISO from Workload details
  VM details lists ready ISOs from that Device Library and attaches one.
  Detach stays. The Library page is unchanged.

  Scenario: ready ISOs are listed excluding already attached
    Given a Workload details page
    And that Device Library has a ready ISO, a downloading ISO, and a cloud image
    And one ready ISO is already attached
    Then Attach ISO lists only the unattached ready ISO

  Scenario: attach posts isoId to attach-iso
    Given I pick a ready ISO on Workload details
    When I Attach
    Then the client POSTs /api/vms/{id}/attach-iso with that isoId
    And the Workload shows the ISO
    And Detach is still available

  Scenario: member attach uses the Home proxy
    Given a Workload on a reachable member Device
    When I Attach ISO
    Then the client POSTs /api/home/devices/{id}/v1/vms/{id}/attach-iso
    And it does not POST /api/vms/{id}/attach-iso on Home

  Scenario: Console lists the same ready ISOs
    Given I open a Workload in Console
    Then Attach lists ready ISOs from that Device Library excluding attached
