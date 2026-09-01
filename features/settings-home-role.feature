Feature: No Role fact on Settings Home
  Settings Home used to show Role / What you can do on this Home.
  That copy is gone. Device URL and Pairing stay.

  Scenario: Web Settings Home has no Role fact
    Given the Settings Home tab
    Then it does not say What you can do on this Home
    And it does not show a Role fact
    And Pairing still has its own tab

  Scenario: Console Settings has no Role fact
    Given Console Settings
    Then it does not say What you can do on this Home
    And it does not show a Role fact

  Scenario: Docs no longer list the Role fact
    Given Settings Home docs
    Then they do not list Role as what your account can do on this Home
