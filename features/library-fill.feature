Feature: Library fill on Create
  The main host holds OS images. Agents copy those bytes on create when the
  guest architecture matches. Architecture mismatches stay a hard block.

  Scenario: Place on an agent copies a fetchable image from the depot
    Given a Home console with a ready image in its Library
    And a paired agent Device of the same architecture without that image
    When I create a Workload on the agent using that image
    Then the agent acquires the image from the depot
    And the Workload is created with the agent's local image id

  Scenario: Place on a foreign-arch Device is blocked
    Given a Home console with a ready arm64 image in its Library
    And a paired x86_64 agent Device
    When I open Create VM and select that image
    Then the x86_64 Device shows an architecture mismatch
    And create does not copy the image onto that Device

  Scenario: Explicit none depot stays internet-only with one peer
    Given a Device with exactly one peer
    And Library depot is set to None
    When I acquire an image that is missing locally
    Then the Device does not copy from the peer
