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
    cy.get('.iface-drawer').contains('button', 'Revert').should('exist')
    cy.get('.iface-drawer').contains('VM network records').should('exist')
  })
})
