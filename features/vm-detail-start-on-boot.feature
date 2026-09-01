Feature: Start when this Device boots sits next to Start
  Autostart used to be a mini On/Off in Hardware facts. It is a labeled toggle next to Start.

  Scenario: Web VM details has a toolbar toggle
    Given I open a Workload details page
    Then a labeled toggle "Start when this Device boots" is next to Start
    And Hardware facts has no Start-on-boot row
    And flipping the toggle PATCHes startOnBoot

  Scenario: Console VM details has a toggle beside Start
    Given I open a Workload in Console
    Then a labeled toggle "Start when this Device boots" is beside Start
    And flipping the toggle PATCHes startOnBoot
