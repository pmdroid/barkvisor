Feature: IOMMU setup docs for GPU passthrough
  Operators enable Intel or AMD IOMMU and vfio-pci on a Linux Device
  before GPU attach. BarkVisor does not auto-setup the host. Host GPU
  blanking and "In use by host" are information, not UI blockers.

  Scenario: guide covers Intel and AMD IOMMU
    Given the GPU passthrough getting-started doc
    Then it names intel_iommu=on
    And it names amd_iommu=on
    And it tells the operator to reboot after update-grub

  Scenario: guide covers vfio-pci and group verification
    Given the GPU passthrough getting-started doc
    Then it loads vfio-pci
    And it lists /sys/kernel/iommu_groups
    And it does not tell the operator to bind vendor:device ids by hand

  Scenario: occupancy and blanking are not blockers
    Given the GPU passthrough getting-started doc
    Then it says passing the host GPU can blank the host display
    And it says that warning does not block Attach
    And it says In use by host is not a blocker

  Scenario: published site and GPU attach link the same guide
    Given the GPU passthrough getting-started doc
    Then website content publishes it under /docs/guides/gpu-passthrough/
    And GPU attach in the web UI and Console links that URL
