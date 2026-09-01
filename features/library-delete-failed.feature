Feature: Delete failed image downloads
  A failed download must not linger in the Library. Deleting the row removes
  the DB record and any partial file, and Home-union rows delete on the
  Device that owns the copy.

  Scenario: Delete a failed download from the Images list
    Given an image download that ended in error status
    And a partial file for that download in the Library folder
    When I delete the failed row from the Images list
    Then the row is gone from the list
    And the image record is gone from the DB
    And the partial file is gone from the Library folder

  Scenario: Delete a failed download owned by a member Device
    Given a Home with a paired member Device
    And a failed image download in the member's Library
    When I delete that row from the Home Images list
    Then the delete is sent to the owning Device, not This Device
    And the member's image record is gone from its DB

  Scenario: Delete a failed download in Console
    Given a Console connected to a Device with a failed download in its Library
    When I tap Delete on the failed row
    Then the row is gone from the Console Library list
    And the image record is gone from the Device's DB
