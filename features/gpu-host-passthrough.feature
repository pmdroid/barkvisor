Feature: Host GPU passthrough is allowed
  Operators can pass through the host GPU on a Linux Device, including
  when that Device lists one GPU. Occupancy is a fact. It does not disable Attach
  on a Workload.

  Scenario: Web GPU picker has no single-GPU warning
    Given GPU passthrough copy in the web UI
    Then it does not say This machine lists one GPU
    And it does not say In use by host
    And occupancy copy is Host GPU driver

  Scenario: Console GPU picker has no single-GPU warning
    Given GPU passthrough copy in Console
    Then Workload detail does not warn about one GPU
    And Device detail does not warn about one GPU
    And occupancy does not say In use by host

  Scenario: Occupancy does not disable Attach
    Given a GPU whose host driver still owns the card
    Then Attach stays enabled on the Workload
    And the picker does not dim the row for occupancy
