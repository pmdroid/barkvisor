# Local guest-boot BDD (PAS-183).
# Mapped by scripts/guest-boot-bdd.sh onto:
#   scripts/linux-guest-smoke.sh       (blank disk)
#   scripts/linux-real-guest-smoke.sh  (REAL_GUEST=1 cloud image + SSH)
# Run: mise run guest-smoke | mise run guest-smoke-real
# Not part of default `mise run prepush`. Optional: mise run prepush-full
#
# Expected runtime:
#   blank disk: seconds to a couple of minutes (QEMU starts; no guest OS)
#   REAL_GUEST: minutes on KVM/HVF; up to ~15 minutes on TCG (SSH_WAIT_SECS=900)
#
# When qemu-system-* is missing the mapper SKIPs with a clear message (exit 0).
# Set ALLOW_NO_QEMU=1 to exercise API create-only instead of skipping.
#
# Out of scope: Windows ISO guests, Cypress/UI, cross-Device Home proxy, CI wiring.

Feature: Local guest-boot on one Device
  A Device owns its runtime in local SQLite. Creating and starting a Workload
  on this Device does not require other Devices in the Home to be reachable.

  Background:
    Given a local BarkVisor Device
    And qemu-system-aarch64 or qemu-system-x86_64 is on PATH

  @blank @guest-smoke
  Scenario: a blank-disk Workload reaches running
    Given no cloud image URL is set
    And setup has completed through the API
    And a default NAT network exists
    When I create a Workload from a blank disk
    And I start the Workload
    Then the Workload state is running or starting

  @real @guest-smoke-real
  Scenario: a Linux Workload boots from a cloud image and answers SSH
    Given REAL_GUEST uses the host-arch Ubuntu cloud image
    And setup has completed through the API
    And a default NAT network exists
    When I download the cloud image into the Library
    And I create a Workload from that image with cloud-init SSH
    And I start the Workload
    Then the Workload state is running
    And guest SSH answers
