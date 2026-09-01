Feature: Create VM magazine wizard

  Scenario: Gallery cards do not show architecture labels
    Given the Create VM dialog is open on step 1
    Then template cards should not display arm64 or x86_64 badges

  Scenario: Cloud-init guests show hostname hint on step 2
    Given the Create VM dialog is open with a cloud-init template selected
    When I am on step 2
    Then I should see a hostname hint under the name field

  Scenario: Windows and ISO guests do not show hostname hint
    Given the Create VM dialog is open with Windows selected
    When I am on step 2
    Then I should not see a hostname hint under the name field

  Scenario: Host buffer rejects allocating all host cores
    Given a Device with 10 logical CPUs
    When I try to create a VM with 10 cores
    Then validation should reject the request

  Scenario: Raw host disk option is dimmed on macOS Devices
    Given the Create VM dialog is on step 3
    And the picked Device runs macOS
    Then the raw host device card should be disabled

  Scenario: Gallery template card opens configure then disk
    Given the Create VM dialog is open on step 1
    When I pick a cloud OS template
    Then I should be on step 2
    And the name field should be filled
    When I continue to disk
    Then I should be on step 3
    And Create should be enabled for a new qcow2 disk

  Scenario: Cloud OS templates do not ask for a guest password
    Given the Create VM dialog is open with Ubuntu or Debian selected
    Then there should be no password field
    And an SSH key should be required before Next

  Scenario: SSH key picker labels stay readable
    Given a single SSH key named Github exists
    When the Create VM dialog asks for an SSH key
    Then the picker should show Github without a default suffix
    When a second key exists and Github is the default
    Then the picker should show Github (default) and the other key by name

  Scenario: Add another key stays in the dialog and selects the new key
    Given the Create VM dialog is open with a cloud OS template selected
    And I have filled in a name on step 2
    When I add a new SSH key from the dialog
    Then the new key should be selected in the picker
    And the wizard should stay on step 2 with my name intact

  Scenario: Console Create VM adds a key without leaving configure
    Given the Console Create Workload wizard is on configure
    When I add a new SSH key from the wizard
    Then the new key should be selected in the picker
    And the wizard should stay on configure with my name intact

  Scenario: Custom image flow requires an image on configure
    Given the Create VM dialog is open on step 1
    When I choose Use your own image
    Then Next should stay disabled until I pick an image

  Scenario: Windows install ISO is on configure and VirtIO is background
    Given the Create VM dialog is open on step 1
    When I pick Windows
    Then the guest should be Windows on ISO mode
    And step 2 should show Install ISO
    And there should be no Drivers wizard step
    And Next should stay disabled until an ISO is picked
    And Create should not wait for VirtIO to finish downloading

  Scenario: Use your own image pins a file or URL for this VM
    Given the Create VM dialog is open on step 1
    When I choose Use your own image
    Then step 2 should let me upload a file or pin a URL
    And that image is the selected image for this VM only

  Scenario: Windows flow is ISO only
    Given the Create VM dialog is open on step 1
    When I pick Windows
    Then the guest should be Windows on ISO mode
    And Next should stay disabled until an ISO is picked

  Scenario: Existing unused disk can be attached on step 3
    Given the Create VM dialog is on step 3
    When I pick Existing disk
    Then Create should stay disabled until I pick an unused disk

  Scenario: Light mode uses the same surface tokens as other modals
    Given the console is in light mode
    When I open Create VM
    Then the magazine frame should use the light modal surface

  Scenario: Create from a cloud template deploys without a password input
    Given an SSH key exists in Settings
    And the Create VM dialog is open with a cloud OS template selected
    When I pick the SSH key and a new disk
    And I click Create
    Then the request must not include an empty password
    And the magazine should close
    And the Workloads list should show downloading or provisioning for that VM

  Scenario: Create from a recipe the Device never synced still deploys
    Given the gallery shows a Home template the picked Device has not synced
    When I click Create
    Then the deploy request includes the Home recipe
    And the Device downloads the image bytes itself
