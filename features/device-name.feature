Feature: Device display name
  Each Device has a name people see in the Home. Hostname is the default.
  Setup can set it. Settings can rename it later. Lists show that name,
  not "This Device".

  Scenario: unset name is the hostname
    Given no device_display_name is stored
    When I GET /api/system/device-name
    Then the response is 200
    And displayName is the hostname

  Scenario: setup can set the name before complete
    Given setup is not finished
    When I PUT /api/setup/device-name with displayName "Studio Mac"
    Then the response is 200
    And displayName is "Studio Mac"

  Scenario: settings can rename later
    Given I am authenticated
    When I PUT /api/system/device-name with displayName "Garage PC"
    Then the response is 200
    And GET /api/home/devices/health lists this Device as "Garage PC"

  Scenario: empty name is rejected
    Given I am authenticated
    When I PUT /api/system/device-name with displayName "   "
    Then the response is 400
