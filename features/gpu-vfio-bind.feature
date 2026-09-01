Feature: GPU passthrough vfio-pci bind preflight
  Attaching a GPU to a Workload binds the device to vfio-pci through sysfs.
  Every sysfs node is checked before it is written. When a node is missing,
  the error names the exact path and the likely cause so the operator can fix
  the Device. BarkVisor never loads kernel modules or edits boot configuration.

  Background:
    Given a Workload with a GPU attached for passthrough

  Scenario: bind succeeds when IOMMU and vfio-pci are set up
    Given the device exists under /sys/bus/pci/devices
    And the device has an iommu_group
    And the vfio-pci driver directory exists with its bind node
    When the Workload starts
    Then the device driver symlink points at vfio-pci

  Scenario: missing vfio-pci driver directory names the path and the module
    Given /sys/bus/pci/drivers/vfio-pci does not exist
    When the Workload starts
    Then the start fails before any sysfs write
    And the error names /sys/bus/pci/drivers/vfio-pci
    And the error says the vfio-pci kernel module is not loaded

  Scenario: missing bind node names the exact path
    Given /sys/bus/pci/drivers/vfio-pci exists
    But /sys/bus/pci/drivers/vfio-pci/bind does not exist
    When the Workload starts
    Then the error names /sys/bus/pci/drivers/vfio-pci/bind

  Scenario: device without an IOMMU group names the group path
    Given the device has no iommu_group node in sysfs
    When the Workload starts
    Then the start fails before any sysfs write
    And the error names the device iommu_group path
    And the error says the IOMMU is disabled or unsupported

  Scenario: the detailed error reaches web and Console attach
    Given a bind preflight error occurred
    When the web UI or Console attaches or starts the Workload
    Then the toast or banner shows the server error message verbatim
