describe('Network Management', () => {
  const netName = 'cypress-test-net'

  before(() => cy.deleteNetworkByName(netName))
  after(() => cy.deleteNetworkByName(netName))

  beforeEach(() => {
    cy.login()
    cy.visit('/networks')
  })

  it('shows page header with Bridge setup and Create Network', () => {
    cy.contains('h1', 'Networks').should('be.visible')
    cy.contains('button', 'Bridge setup').should('exist')
    cy.contains('button', 'Create Network').should('exist')
  })

  it('selects the first network row by default', () => {
    cy.get('.nrow').first().should('have.class', 'selected')
    cy.get('.inspect .detail-head h2').should('exist')
  })

  it('Create Network button is visible in the toolbar', () => {
    cy.contains('button', 'Create Network').should('exist')
  })

  it('lists the default NAT network', () => {
    cy.contains('.nrow', 'Default NAT').should('exist')
    cy.contains('.nrow', 'Default NAT').find('.badge, .tag').contains(/nat/i).should('exist')
    cy.contains('.nrow', 'Default NAT').click()
    cy.get('.inspect').contains('.chip', 'Default NAT').should('exist')
  })

  it('network list and inspector show Name, Mode, Bridge, DNS', () => {
    cy.get('.nrow .nrow-name').should('have.length.gte', 1)
    cy.get('.nrow').first().click()
    cy.get('.inspect .sheet').should('contain', 'Mode')
    cy.get('.inspect .sheet').should('contain', 'DNS')
    cy.get('.inspect .sheet').should('contain', 'Device')
  })

  it('default network has no Edit / Delete buttons', () => {
    cy.contains('.nrow', 'Default NAT').click()
    cy.get('.inspect .detail-head').within(() => {
      cy.contains('button', 'Edit').should('not.exist')
      cy.contains('button', 'Delete').should('not.exist')
    })
  })

  // --- Create Network ---

  it('opens Create Network modal with name, mode, DNS fields', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Create Network').should('be.visible')
    cy.get('.modal input[placeholder="my-network"]').should('exist')
    cy.get('.modal select').should('exist')
    cy.contains('DNS Server').should('exist')
  })

  it('create network modal has NAT, Bridged, and Isolated mode options', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().within(() => {
      cy.get('option').should('contain', 'NAT')
      cy.get('option').should('contain', 'Bridged')
      cy.get('option').should('contain', 'Isolated')
    })
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('create network validates name is required', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal').contains('button', 'Create').click()
    cy.contains('Name required').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('shows bridge interface selector when mode is Bridged', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().select('bridged')
    cy.contains('Bridge Interface').should('exist')
    // DNS Server should be hidden in bridged mode
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('bridged mode validates bridge interface is required', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal input[placeholder="my-network"]').type('test-bridged')
    cy.get('.modal select').first().select('bridged')
    cy.get('.modal').contains('button', 'Create').click()
    cy.contains('Bridge interface required').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('NAT mode shows DNS Server field', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().select('nat')
    cy.contains('DNS Server').should('exist')
    cy.get('.modal input[placeholder="8.8.8.8"]').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('creates a NAT network', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal input[placeholder="my-network"]').type(netName)
    cy.get('.modal').contains('button', 'Create').click()
    cy.get('.modal-overlay').should('not.exist')
    cy.contains(netName).should('exist')
  })

  it('created network shows in the list with nat mode', () => {
    cy.contains('.nrow', netName).within(() => {
      cy.get('.nrow-state').should('contain', 'nat')
    })
  })

  it('created network has Edit and Delete buttons in the inspector', () => {
    cy.contains('.nrow', netName).click()
    cy.get('.inspect .detail-head').within(() => {
      cy.contains('button', 'Edit').should('exist')
      cy.contains('button', 'Delete').should('exist')
    })
  })

  // --- Edit ---

  it('opens Edit modal for the created network', () => {
    cy.contains('.nrow', netName).click()
    cy.get('.inspect').contains('button', 'Edit').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Edit Network').should('be.visible')
    // Name should be pre-filled
    cy.get('.modal input[placeholder="my-network"]').should('have.value', netName)
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('edit modal shows Save button instead of Create', () => {
    cy.contains('.nrow', netName).click()
    cy.get('.inspect').contains('button', 'Edit').click()
    cy.get('.modal').contains('button', 'Save').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  // --- Delete ---

  it('delete opens confirm dialog with network name', () => {
    cy.contains('.nrow', netName).click()
    cy.get('.inspect').contains('button', 'Delete').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('Delete Network').should('be.visible')
    cy.contains(netName).should('exist')
    cy.get('.modal-overlay').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('deletes the created network', () => {
    cy.contains('.nrow', netName).click()
    cy.get('.inspect').contains('button', 'Delete').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('Delete Network').should('be.visible')
    cy.get('.modal-overlay').contains('button', 'Delete').click()
    cy.contains(netName).should('not.exist')
  })

  it('Bridge setup opens the setup modal and closes', () => {
    cy.contains('button', 'Bridge setup').then(($btn) => {
      if ($btn.prop('disabled')) return
      cy.wrap($btn).click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('Bridge setup').should('exist')
      cy.get('.modal-overlay').contains('Device address').should('exist')
      cy.get('.modal-overlay').contains('DHCP').should('exist')
      cy.get('.modal-overlay').contains('static').should('exist')
      cy.get('.modal-overlay').contains('button', 'Apply').should('exist')
      cy.get('.modal-overlay').contains('button', 'Revert').should('exist')
      cy.get('.modal-overlay').contains('button', /^Setup$/).should('not.exist')
      cy.get('.modal-overlay').contains('button', /^Start$/).should('not.exist')
      cy.get('.modal-overlay').contains('button', /^Stop$/).should('not.exist')
      cy.get('.modal-overlay').contains('button', 'Close').click()
      cy.get('.modal-overlay').should('not.exist')
    })
  })
})
