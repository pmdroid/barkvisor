Feature: Create VM placement scores a template by every arch it declares

  @bdd-template-score-both-arches
  Scenario: A dual-arch template scores an x86 Device as eligible from an arm64 console
    Given the console Device is arm64 and Debian 13 declares arm64 and x86_64 with an x86_64 catalog image
    When the operator selects Debian 13 in Create VM
    Then the placement score body lists arm64 and x86_64 and the x86_64 Device has no architecture mismatch

  @bdd-template-score-drops-stale-mismatch
  Scenario: A new score hides the previous architecture mismatch immediately
    Given the picker is showing Architecture (arm64) is not compatible with this Device (x86_64) from an earlier score
    When a new placement score starts for a different architecture list
    Then that hard reason is gone before the new score returns

  @bdd-single-arch-image-still-rejects-other-device
  Scenario: An arm64-only image still rejects an x86 Device
    Given the selected Library image arch is arm64
    When Create VM scores placement
    Then the x86_64 Device is incompatible because Architecture (arm64) is not compatible with this Device (x86_64)
