Feature: Home is the only GitHub catalog fetcher
  Only Home GETs repos/templates.json and repos/images.json. Members receive
  catalog JSON over the authenticated agent plane. Deploy can still use the
  recipe in the request when a Device never synced GitHub.

  Scenario: Member seed does not create GitHub-URL built-in repos
    Given a Device that has joined a Home
    When the Device seeds built-in repositories
    Then those rows use the Home catalog origin
    And existing GitHub built-in URLs are flipped

  Scenario: Catalog JSON reaches a member over the agent plane
    Given Home has fetched the GitHub catalogs
    When Home publishes the verbatim catalog bytes
    Then the member stores last-good JSON
    And the member applies that JSON without fetching GitHub

  Scenario: Member without a GitHub route can still deploy
    Given a Home template recipe in the deploy request
    And the member has no route to GitHub
    When I deploy that template onto the member
    Then the member downloads the image from the recipe URL

  Scenario: Built-in catalogs sync in the background
    Given a Device that has completed setup
    When the daemon starts
    Then built-in catalogs sync without blocking listen
    And a daily catalog sync is scheduled
    And Library settings report lastSyncedAt

  Scenario: Missing catalog image retries after one sync
    Given a template whose image slug is absent from the catalog
    When I deploy that template without a recipe
    Then the daemon syncs built-in catalogs once
    And deploy succeeds if the image appears
