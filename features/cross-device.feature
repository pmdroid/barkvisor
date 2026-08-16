# Cross-Device Home proxy BDD (PAS-185).
# Mapped by scripts/cross-device-smoke.sh onto two real daemons on one host.
# Run: mise run cross-device-smoke
# Not part of default `mise run prepush`.
#
# Two processes, two BARKVISOR_DATA_DIRs, two HTTP ports, two agent ports.
# Device B joins Device A's Home via real /api/pairing/codes + /api/pairing/join.
# Create + start go through Home /api/home/devices/:id/v1 and are asserted
# on the Home proxy and on Device B locally.
#
# Pairing join cannot advertise 127.0.0.1 (LAN-only redeem). The host needs
# an RFC1918 address. After join the member daemon is restarted so the
# agent plane presents the Home-issued Device certificate.
#
# Out of scope: more than two Devices, auto-placement, template deploy via
# proxy, UI/Cypress, first-time join only, any in-process fake topology, CI wiring.

Feature: Cross-Device Home proxy
  Each Device owns its runtime in local SQLite and its own Library. A Home
  can create and start a Workload on a paired Device through the member
  proxy. This Device still runs if the other Device is later unreachable.

  Background:
    Given two BarkVisor Devices on one host
    And each Device has its own dataDir, HTTP port, and agent port

  @cross-device @cross-device-smoke
  Scenario: a Workload created from the Home runs on a paired Device
    Given Device A has completed setup and is the Home
    And Device B joins Device A's Home with a real pairing code
    And GET /api/home/devices/health shows Device B reachable
    When I create a Workload on Device B through the Home proxy
    And I start the Workload through the Home proxy
    Then the Workload state is running or starting from the Home proxy
    And the Workload state is running or starting on Device B locally
