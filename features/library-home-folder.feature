Feature: Library home folder
  Each Device stores images in one chosen folder. Unconfigured means no
  explicit saved folder. Saving the default path still counts as chosen.

  Scenario: Images list Delete is visible text
    Given I am on Images with a saved Library folder
    Then each row has a visible Delete button
    And deleting asks for confirmation

  Scenario: Images list Location is device and path
    Given an image with Image.path from VMImage.path
    Then Location shows the Device label, a middle dot, and that path

  Scenario: Unconfigured Library blocks Images until saved
    Given GET /api/system/library/settings returns isDefault true
    When I open Images
    Then I see the Library folder pick form
    And Upload and Download are hidden until save

  Scenario: Settings Library uses the same pick form while unconfigured
    Given GET /api/system/library/settings returns isDefault true
    When I open Settings Library
    Then I see the Library folder pick form
    And Select This Folder works after choosing a Places root
    And a typed path plus Save counts as chosen

  Scenario: Saving the default path is explicit
    Given no Library folder is stored
    When I PUT the default image directory
    Then GET isDefault is false

  Scenario: Empty PUT unconfigures the Library
    When I PUT imageDirectory as empty
    Then GET isDefault is true

  Scenario: Setup requires a Library folder after Admin
    Given first-run setup after the Admin step
    Then Continue on the Library step is disabled until save
    And POST /api/setup/complete is 400 until a folder is saved
    And setup uses /api/setup/library and /api/setup/browse without JWT

  Scenario: Changing the Library directory does not migrate images
    When I save a different Library folder
    Then existing image files stay where they are
