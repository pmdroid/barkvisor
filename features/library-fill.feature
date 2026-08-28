Feature: Library fill on Create
  The main host holds OS images. Missing images download from the internet
  when the guest architecture matches. Architecture mismatches stay a hard block.

  Scenario: Place on an agent downloads a missing image from the internet
    Given a Home console with a ready image in its Library
    And a paired agent Device of the same architecture without that image
    When I create a Workload on the agent using that image
    Then the agent downloads the image from the internet
    And the Workload is created with the agent's local image id

  Scenario: Place on a foreign-arch Device is blocked
    Given a Home console with a ready arm64 image in its Library
    And a paired x86_64 agent Device
    When I open Create VM and select that image
    Then the x86_64 Device shows an architecture mismatch
    And create does not copy the image onto that Device
