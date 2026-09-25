Feature: Serve the template list without a live host probe

  @template-list-skips-live-docker
  Scenario: The template list returns without a live Docker probe
    Given the Docker discovery cache is cold and a catalog with Debian 13 is stored
    When the client GET /api/templates
    Then the response includes Debian 13 and both catalog image arches and the handler did not call DockerEngine.liveSnapshot

  @template-deploy-still-checks-features
  Scenario: Deploy still rejects a template feature the host does not have
    Given a template requires dockerEngine and this Device does not have it
    When the operator dry-runs or deploys that template
    Then template compatibility rejects the deploy for the missing feature
