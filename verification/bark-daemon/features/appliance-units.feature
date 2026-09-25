Feature: Installed services are BarkDaemon and BarkServer
  Scenario: enablement, socket permissions, and a rejected downgrade
    When the appliance unit suite runs
    Then the appliance unit suite passes
