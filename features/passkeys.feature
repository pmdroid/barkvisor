Feature: WebAuthn passkeys for web login
  Passkeys are additive. Password login stays. Register and list
  require a session. Login begin is public and rate-limited.

  Scenario: login begin is unauthenticated and returns a ceremony
    When I POST /api/auth/passkeys/login/begin with {}
    Then the response is 200
    And the body has sessionId and publicKey

  Scenario: login finish with junk is 4xx
    When I POST /api/auth/passkeys/login/finish with a junk credential
    Then the response is 4xx

  Scenario: register begin without JWT is 401
    When I POST /api/auth/passkeys/register/begin without Authorization
    Then the response is 401

  Scenario: list after login is empty until a passkey is added
    Given I am authenticated
    When I GET /api/auth/passkeys
    Then the response is 200
    And the body is []

  Scenario: IP host is rejected
    When the Host header is an IPv4 or IPv6 address
    And I POST /api/auth/passkeys/login/begin
    Then the response is 400
    And the reason says passkeys need a hostname
