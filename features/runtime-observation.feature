Feature: Centralized runtime observation
  BarkDaemon collects Docker and QMP facts once per Device and publishes one bounded view.

  Scenario: batched stats and cached discovery stay bounded
    Given the runtime observation evidence file
    When the evidence is loaded
    Then twenty polling rounds resolve discovery once and a context change resolves it again
    And one running app and four running apps each use two docker commands in a round
    And the legacy per-app round used two commands for one app and eight commands for four apps
    And event delivery stays under 50 milliseconds
    And idle observation keeps the process under 50 cpu ticks
    And the evidence records idle rss and the failed-probe flag
