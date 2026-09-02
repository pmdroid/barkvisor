describe('Network Management', () => {
  const netName = 'cypress-test-net'

  function openVmNetworksTab() {
    cy.contains('[role="tab"]', 'VM networks').click()
  }

  before(() => cy.deleteNetworkByName(netName))
  after(() => cy.deleteNetworkByName(netName))

  beforeEach(() => {
    cy.login()
    cy.visit('/networks')
  })

  it('shows segmented tabs with Host interfaces default', () => {
    cy.contains('h1', 'Networks').should('be.visible')
    cy.contains('[role="tab"]', 'Host interfaces').should('have.attr', 'aria-selected', 'true')
    cy.contains('[role="tab"]', 'VM networks').should('exist')
    cy.contains('button', 'Bridge setup').should('not.exist')
    cy.get('.iface-row').should('exist')
    cy.contains('button', 'Create Network').should('not.exist')
  })

  it('VM networks tab shows Create Network and Workload network copy', () => {
    openVmNetworksTab()
    cy.contains('[role="tab"]', 'VM networks').should('have.attr', 'aria-selected', 'true')
    cy.contains('button', 'Create Network').should('be.visible')
    cy.contains('Workload networks are logical').should('be.visible')
    cy.contains('Device addresses').should('be.visible')
  })

  it('selects the first network row by default on VM tab', () => {
    openVmNetworksTab()
    cy.get('.nrow').first().should('have.class', 'selected')
    cy.get('.inspect .detail-head h2').should('exist')
  })

  it('lists the default NAT network', () => {
    openVmNetworksTab()
    cy.contains('.nrow', 'Default NAT').should('exist')
    cy.contains('.nrow', 'Default NAT').find('.badge, .tag').contains(/nat/i).should('exist')
    cy.contains('.nrow', 'Default NAT').click()
    cy.get('.inspect').contains('.chip', 'Default NAT').should('exist')
    cy.get('.inspect .detail-meta').should('contain', 'Workload network')
  })

  it('network list and inspector show Mode, DNS, Device', () => {
    openVmNetworksTab()
    cy.get('.nrow .nrow-name').should('have.length.gte', 1)
    cy.get('.nrow').first().click()
    cy.get('.inspect .sheet').should('contain', 'Mode')
    cy.get('.inspect .sheet').should('contain', 'DNS')
    cy.get('.inspect .sheet').should('contain', 'Device')
  })

  it('default network has no Edit / Delete buttons', () => {
    openVmNetworksTab()
    cy.contains('.nrow', 'Default NAT').click()
    cy.get('.inspect .detail-head').within(() => {
      cy.contains('button', 'Edit').should('not.exist')
      cy.contains('button', 'Delete').should('not.exist')
    })
  })

  // --- Create Network ---

  it('opens Create Workload network modal with name, mode, DNS fields', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Create Workload network').should('be.visible')
    cy.get('.modal input[placeholder="my-network"]').should('exist')
    cy.get('.modal select').should('exist')
    cy.contains('DNS Server').should('exist')
    cy.contains('Device addresses').should('be.visible')
  })

  it('create network modal has NAT, Bridged, and Isolated mode options', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().within(() => {
      cy.get('option').should('contain', 'NAT')
      cy.get('option').should('contain', 'Bridged')
      cy.get('option').should('contain', 'Isolated')
    })
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('create network validates name is required', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal').contains('button', 'Create').click()
    cy.contains('Name required').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('shows host bridge interface selector when mode is Bridged', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().select('bridged')
    cy.contains('Host bridge interface').should('exist')
    cy.contains('Host interfaces tab').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('bridged mode validates bridge interface is required', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal input[placeholder="my-network"]').type('test-bridged')
    cy.get('.modal select').first().select('bridged')
    cy.get('.modal').contains('button', 'Create').click()
    cy.contains('Bridge interface required').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('NAT mode shows DNS Server field', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().select('nat')
    cy.contains('DNS Server').should('exist')
    cy.get('.modal input[placeholder="8.8.8.8"]').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('creates a NAT network', () => {
    openVmNetworksTab()
    cy.contains('button', 'Create Network').click()
    cy.get('.modal input[placeholder="my-network"]').type(netName)
    cy.get('.modal').contains('button', 'Create').click()
    cy.get('.modal-overlay').should('not.exist')
    cy.contains(netName).should('exist')
  })

  it('created network shows in the list with nat mode', () => {
    openVmNetworksTab()
    cy.contains('.nrow', netName).within(() => {
      cy.get('.tag').should('contain', 'NAT')
    })
  })

  it('created network has Edit and Delete buttons in the inspector', () => {
    openVmNetworksTab()
    cy.contains('.nrow', netName).click()
    cy.get('.inspect .detail-head').within(() => {
      cy.contains('button', 'Edit').should('exist')
      cy.contains('button', 'Delete').should('exist')
    })
  })

  // --- Edit ---

  it('opens Edit modal for the created network', () => {
    openVmNetworksTab()
    cy.contains('.nrow', netName).click()
    cy.get('.inspect .detail-head').contains('button', 'Edit').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Edit Workload network').should('be.visible')
    cy.get('.modal input[placeholder="my-network"]').should('have.value', netName)
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('edit modal shows Save button instead of Create', () => {
    openVmNetworksTab()
    cy.contains('.nrow', netName).click()
    cy.get('.inspect .detail-head').contains('button', 'Edit').click()
    cy.get('.modal').contains('button', 'Save').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  // --- Delete ---

  it('delete opens confirm dialog with network name', () => {
    openVmNetworksTab()
    cy.contains('.nrow', netName).click()
    cy.get('.inspect .detail-head').contains('button', 'Delete').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('Delete Network').should('be.visible')
    cy.contains(netName).should('exist')
    cy.get('.modal-overlay').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('deletes the created network', () => {
    openVmNetworksTab()
    cy.contains('.nrow', netName).click()
    cy.get('.inspect .detail-head').contains('button', 'Delete').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('Delete Network').should('be.visible')
    cy.get('.modal-overlay').contains('button', 'Delete').click()
    cy.contains(netName).should('not.exist')
  })

  it('Host interfaces tab shows interface table and edit drawer', () => {
    cy.contains('[role="tab"]', 'Host interfaces').should('have.attr', 'aria-selected', 'true')
    cy.get('.iface-row').should('have.length.gte', 1)
    cy.get('.iface-drawer').should('exist')
    cy.get('.iface-drawer').contains('button', 'Apply').should('exist')
    cy.get('.iface-drawer').contains('button', 'Revert').should('not.exist')
    cy.get('.iface-drawer').contains('button', 'Re-check').should('not.exist')
    cy.get('.iface-drawer').contains('VM network records').should('not.exist')
    cy.contains('DHCP is always on').should('not.exist')
    cy.contains('Advanced CLI').should('not.exist')
  })

  function stubLinuxHost() {
    cy.intercept('GET', '**/system/capabilities', (req) => {
      req.continue((res) => {
        if (res.body && typeof res.body === 'object') {
          res.body.platform = 'Linux'
          res.body.supportsHostBridgeManagement = true
          res.body.supportsManagedBridgeDaemon = false
        }
      })
    })
  }

  function stubCreateBridge(opts: { vmNetwork: boolean; bridge?: string }) {
    const bridge = opts.bridge ?? 'br1'
    cy.intercept('GET', '**/system/bridges/next', { bridge }).as('nextBridge')
    cy.intercept('POST', '**/system/bridges', (req) => {
      expect(req.body.bridge).to.eq(bridge)
      expect(req.body.interface).to.be.a('string').and.not.be.empty
      const checking = req.body.action === 'check'
      req.reply({
        success: true,
        applied: !checking,
        pendingCommit: !checking,
        commitDeadline: checking ? undefined : new Date(Date.now() + 30_000).toISOString(),
        rollbackSeconds: 30,
        target: bridge,
        changes: [`Create Bridge ${bridge}`],
        message: checking ? `Ready to create Bridge ${bridge}.` : `Created Bridge ${bridge}.`,
      })
    }).as('createBridgeApply')
    cy.intercept('POST', '**/networks', (req) => {
      expect(req.body.mode).to.eq('bridged')
      expect(req.body.bridge).to.eq(bridge)
      req.reply({
        id: 'cy-bridged',
        name: req.body.name,
        mode: 'bridged',
        bridge,
        isDefault: false,
      })
    }).as('createVmNetwork')
  }

  it('Create Bridge modal has next-free name and port, no VM network checkbox', () => {
    stubLinuxHost()
    stubCreateBridge({ vmNetwork: true })
    cy.visit('/networks')
    cy.contains('button', 'Create').click()
    cy.contains('button', 'Bridge').click()
    cy.wait('@nextBridge')
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Create Bridge').should('be.visible')
    cy.contains('.form-group', 'Name').find('input').should('have.value', 'br1').and('have.attr', 'readonly')
    cy.contains('Create VM network').should('not.exist')
    cy.get('.modal-overlay').contains('button', 'Apply').should('exist')
    cy.get('.modal-overlay').contains('button', 'Cancel').click()
  })

  it('Create Bridge Apply posts bridge plus nic and creates Workload network', () => {
    stubLinuxHost()
    stubCreateBridge({ vmNetwork: true })
    cy.visit('/networks')
    cy.contains('button', 'Create').click()
    cy.contains('button', 'Bridge').click()
    cy.wait('@nextBridge')
    cy.contains('.form-group', 'Port').find('select').then(($sel) => {
      const values = [...$sel.find('option')].map((o) => o.value).filter((v) => v)
      if (values[0]) cy.wrap($sel).select(values[0], { force: true })
    })
    cy.get('.modal-overlay').contains('button', 'Apply').click()
    cy.wait('@createBridgeApply')
    cy.contains('Apply these network changes').should('be.visible')
    cy.contains('summary', 'Changes').click()
    cy.get('.modal-overlay').contains('button', 'Apply').click()
    cy.wait('@createBridgeApply')
    cy.wait('@createVmNetwork')
  })

  it('Create Bridge on macOS lists Wi-Fi en0 as a port', () => {
    cy.intercept('GET', '**/system/capabilities', (req) => {
      req.continue((res) => {
        if (res.body && typeof res.body === 'object') {
          res.body.platform = 'macOS'
          res.body.supportsHostBridgeManagement = false
          res.body.supportsManagedBridgeDaemon = true
        }
      })
    }).as('macCaps')
    cy.intercept('GET', '**/system/bridges/next', { bridge: 'br0' }).as('nextBridge')
    cy.intercept('GET', '**/system/host-bridge-readiness', {
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
      bridges: [{ name: 'en0', enslaved: [] }],
      defaultRouteInterface: 'en0',
      onlyUplink: false,
      ready: true,
    }).as('ready')
    cy.intercept('GET', '**/system/interfaces', [
      {
        name: 'en0',
        displayName: 'en0 (Wi-Fi)',
        ipAddress: '192.168.1.10',
        dhcpEnabled: true,
        addresses: [{ cidr: '192.168.1.10/24', source: 'dhcp', primary: true }],
      },
    ]).as('ifaces')
    cy.visit('/networks')
    cy.wait('@macCaps')
    cy.contains('button', 'Create').click()
    cy.contains('button', 'Bridge').click()
    cy.wait('@nextBridge')
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Create Bridge').should('be.visible')
    cy.contains('.form-group', 'Port').find('select').should('contain', 'en0')
    cy.get('.modal-overlay').contains('button', 'Cancel').click()
  })

  it('Host interfaces drawer shows multi-address editor', () => {
    cy.get('.iface-drawer').within(() => {
      cy.contains('Addresses').should('be.visible')
      cy.contains('DHCP').should('exist')
      cy.contains('Use DHCP for primary address').should('not.exist')
      cy.contains('Gateway').should('exist')
      cy.contains('DNS').should('exist')
      cy.contains('button', 'Add address').should('exist')
    })
  })

  it('NIC drawer edits addresses; Bridge drawer has no address fields', () => {
    const readiness = {
      helperPath: null,
      helperSetuid: true,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
      bridges: [{ name: 'br0', enslaved: ['eth0'] }],
      defaultRouteInterface: 'eth0',
      onlyUplink: false,
      ready: true,
    }
    cy.intercept('GET', '**/system/interfaces', [
      {
        name: 'eth0',
        displayName: 'eth0',
        ipAddress: '192.168.1.10',
        dhcpEnabled: true,
        addresses: [{ cidr: '192.168.1.10/24', source: 'dhcp', primary: true }],
        gateway: '192.168.1.1',
        dns: ['1.1.1.1'],
      },
      { name: 'br0', displayName: 'br0', ipAddress: '' },
    ]).as('ifaces')
    cy.intercept('GET', '**/system/host-bridge-readiness', readiness).as('ready')
    cy.visit('/networks')
    cy.wait('@ifaces')
    cy.contains('.iface-row', 'br0').click()
    cy.get('.iface-drawer').within(() => {
      cy.contains('Use DHCP for primary address').should('not.exist')
      cy.contains('Attached to eth0').should('be.visible')
    })
    cy.contains('.iface-row', 'eth0').click()
    cy.get('.iface-drawer').within(() => {
      cy.contains('Use DHCP for primary address').should('not.exist')
      cy.contains('DHCP').should('exist')
      cy.get('input[placeholder="from router"]').should('be.disabled')
    })
  })

  it('Keep modal shows when pending nic is the uplink', () => {
    const readiness = {
      helperPath: null,
      helperSetuid: true,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
      bridges: [{ name: 'br0', enslaved: ['en0'] }],
      defaultRouteInterface: 'en0',
      onlyUplink: false,
      ready: true,
      pendingCommit: {
        target: 'en0',
        commitDeadline: new Date(Date.now() + 30_000).toISOString(),
        rollbackSeconds: 30,
      },
    }
    cy.intercept('GET', '**/system/interfaces', [
      { name: 'en0', displayName: 'en0', ipAddress: '192.168.1.10' },
      { name: 'br0', displayName: 'br0', ipAddress: '' },
    ]).as('ifaces')
    cy.intercept('GET', '**/system/host-bridge-readiness', readiness).as('ready')
    cy.visit('/networks')
    cy.wait('@ifaces')
    cy.wait('@ready')
    cy.get('.modal-overlay').contains('Keep network changes').should('be.visible')
    cy.get('.modal-overlay').contains('Keep changes').should('be.visible')
    cy.get('.iface-drawer').contains('Keep changes').should('not.exist')
  })
})
