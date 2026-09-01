Feature: Home Device URL
  Custom hostname from Settings Home persists across reload.
  With Tailscale connected, the default Device URL is MagicDNS over https
  with no port.

  Scenario: save custom Device URL
    Given I am authenticated
    When I PUT /api/home/settings/remote-access with deviceUrl "studio.home"
    Then GET /api/system/remote-access has deviceUrl "studio.home"

  Scenario: paste https URL stores the host
    Given I am authenticated
    When I PUT /api/home/settings/remote-access with deviceUrl "https://nas.lan"
    Then GET /api/system/remote-access has deviceUrl "nas.lan"

  Scenario: Tailscale default is https MagicDNS without a port
    Given Tailscale is connected with MagicDNS "box.tailnet.ts.net"
    And no Device URL is saved
    Then the default Device URL is "https://box.tailnet.ts.net"
    And it has no port

  Scenario: saved URL stays after Tailscale drops
    Given a saved Device URL "studio.home"
    When Tailscale is disconnected
    Then the saved Device URL is still "studio.home"
