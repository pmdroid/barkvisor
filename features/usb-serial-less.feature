Feature: USB attach without a serial

  Serial-less devices (Logitech receiver) can attach. Persist by serial when
  present, else by port path (bus:port). Never invent a serial. Web and Console
  Attach stay on. Copy warns that replug may change the path.

  Scenario: serial-less receiver persists by bus port
    Given a host USB device with no serial at bus 1 address 2
    When I attach it to a Workload
    Then the stored deviceId is bus:001.002
    And serialNumber is absent

  Scenario: serial device still persists by serial
    Given a host USB device with serial ZX9 at bus 3 address 2
    When I attach it by bus:003.002
    Then the stored deviceId is the serial identity
    And serialNumber is ZX9

  Scenario: web and Console enable Attach
    Given a serial-less device listed as bus:001.002
    Then Attach is enabled
    And copy warns that replug may change the path

  Scenario: QEMU uses live bus address for serial-less persist
    Given a stored bus:003.002 device with no serial
    And the live host is still at that address
    When QEMU args are built
    Then they contain hostbus=3,hostaddr=2
    And they do not contain vendorid=
