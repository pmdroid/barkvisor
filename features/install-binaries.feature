Feature: Two Device binaries
  Packages ship barkvisor (SPA Home Device) and barkvisor-agent (API-only Device).
  One process per Device. The two systemd units Conflict.

  Scenario: Home Device uses barkvisor
    Given a packaged install
    Then /usr/local/bin/barkvisor is present
    And barkvisor.service ExecStart is /usr/local/bin/barkvisor
    And the default enabled unit is barkvisor.service

  Scenario: API-only Device uses barkvisor-agent
    Given a packaged install
    Then /usr/local/bin/barkvisor-agent is present
    And barkvisor-agent.service ExecStart is /usr/local/bin/barkvisor-agent
    And barkvisor.service Conflicts with barkvisor-agent.service
    And invoking barkvisor-agent does not serve the SPA
