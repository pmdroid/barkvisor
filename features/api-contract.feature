# API contract BDD (PAS-188).
# Walks every operation in docs/api/openapi.yaml against a real local Device.
# Mapped by scripts/api-contract-bdd.sh. Run: mise run api-bdd
# Fast. No QEMU required. Not in default `mise run prepush`.
# Optional: mise run prepush-full (includes this after guest-smoke).
#
# Fail = documented route returns 404 or 5xx.
# SKIP is allowed for SSE/WebSocket, VNC/console upgrade, mTLS-only bytes,
# and Home proxy methods that need a second Device.
#
# Out of scope: guest boot (PAS-183), Cypress, inventing undocumented routes.

Feature: Documented API contract on one Device
  The OpenAPI document is the stable baseline. After setup, every documented
  JSON operation is reachable on this Device. Missing routes (404) and
  server errors (5xx) fail the baseline.

  Background:
    Given a local BarkVisor Device
    And setup has completed through the API
    And I am authenticated as the admin

  @api @api-bdd
  Scenario: every documented API operation is probed
    Given docs/api/openapi.yaml lists the contract operations
    And seed Workload, disk, and network ids exist when the path needs {id}
    When I probe each OpenAPI method and path
    Then no documented operation returns 404 or 5xx
    And every operation is HIT or SKIP with a reason
    And the report names any OpenAPI path that was not probed
