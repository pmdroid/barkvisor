describe('Network Management', () => {
  const netName = 'cypress-test-net'

  before(() => cy.deleteNetworkByName(netName))
  after(() => cy.deleteNetworkByName(netName))

  beforeEach(() => {
    cy.login()
    cy.visit('/networks')
  })

  it('shows page header with Networks / Bridge Management tabs', () => {
    cy.contains('h1', 'Networks').should('be.visible')
    cy.get('.tab-bar button').should('contain', 'Networks')
    cy.get('.tab-bar button').should('contain', 'Bridge Management')
  })

  it('Networks tab is active by default', () => {
    cy.get('.tab-bar button').contains('Networks').should('have.class', 'active')
  })

  it('Create Network button is visible on Networks tab', () => {
    cy.contains('button', 'Create Network').should('exist')
  })

  it('Create Network button is hidden on Bridge Management tab', () => {
    cy.get('.tab-bar button').contains('Bridge Management').click()
    cy.contains('button', 'Create Network').should('not.exist')
  })

  it('lists the default NAT network', () => {
    cy.contains('Default NAT').should('exist')
    cy.get('.badge').contains('nat').should('exist')
  })

  it('network table shows Name, Mode, Bridge, DNS columns', () => {
    cy.get('table thead th').should('contain', 'Name')
    cy.get('table thead th').should('contain', 'Mode')
    cy.get('table thead th').should('contain', 'Bridge')
    cy.get('table thead th').should('contain', 'DNS')
  })

  it('default network has no Edit / Delete buttons', () => {
    cy.contains('tr', 'Default NAT').then(($row) => {
      expect($row.find('button:contains("Edit")').length).to.equal(0)
      expect($row.find('button:contains("Delete")').length).to.equal(0)
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

  it('create network modal has NAT and Bridged mode options', () => {
    cy.contains('button', 'Create Network').click()
    cy.get('.modal select').first().within(() => {
      cy.get('option').should('contain', 'NAT')
      cy.get('option').should('contain', 'Bridged')
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

  it('created network shows in table with nat mode badge', () => {
    cy.contains('tr', netName).within(() => {
      cy.get('.badge').should('contain', 'nat')
    })
  })

  it('created network has Edit and Delete buttons', () => {
    cy.contains('tr', netName).within(() => {
      cy.contains('button', 'Edit').should('exist')
      cy.contains('button', 'Delete').should('exist')
    })
  })

  // --- Edit ---

  it('opens Edit modal for the created network', () => {
    cy.contains('tr', netName).contains('button', 'Edit').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Edit Network').should('be.visible')
    // Name should be pre-filled
    cy.get('.modal input[placeholder="my-network"]').should('have.value', netName)
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('edit modal shows Save button instead of Create', () => {
    cy.contains('tr', netName).contains('button', 'Edit').click()
    cy.get('.modal').contains('button', 'Save').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  // --- Delete ---

  it('delete opens confirm dialog with network name', () => {
    cy.contains('tr', netName).contains('button', 'Delete').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('Delete Network').should('be.visible')
    cy.contains(netName).should('exist')
    cy.get('.modal-overlay').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('deletes the created network', () => {
    cy.contains('tr', netName).contains('button', 'Delete').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('Delete Network').should('be.visible')
    cy.get('.modal-overlay').contains('button', 'Delete').click()
    cy.contains(netName).should('not.exist')
  })

  // --- Bridge Management tab ---

  it('switches to Bridge Management tab and shows interface table', () => {
    cy.get('.tab-bar button').contains('Bridge Management').click()
    // Should show interfaces table (may take a moment to load)
    cy.get('table thead', { timeout: 5000 }).should('contain', 'Interface')
    cy.get('table thead').should('contain', 'IP Address')
    cy.get('table thead').should('contain', 'Bridge Status')
  })

  it('bridge table shows status badges for each interface', () => {
    cy.get('.tab-bar button').contains('Bridge Management').click()
    cy.get('table tbody tr', { timeout: 5000 }).should('have.length.gte', 1)
    cy.get('table tbody .badge').should('have.length.gte', 1)
    // Badges should show active, installed, or no bridge
    cy.get('table tbody .badge').first().invoke('text').should('match', /active|installed|no bridge/)
  })

  it('bridge table rows have action buttons based on bridge status', () => {
    cy.get('.tab-bar button').contains('Bridge Management').click()
    cy.get('table tbody tr', { timeout: 5000 }).should('have.length.gte', 1)
    // Each row should have at least one action button
    cy.get('table tbody tr').first().within(() => {
      cy.get('button').should('have.length.gte', 1)
    })
  })

  it('switching between tabs preserves network list', () => {
    cy.contains('Default NAT').should('exist')
    cy.get('.tab-bar button').contains('Bridge Management').click()
    cy.get('table thead').should('contain', 'Interface')
    cy.get('.tab-bar button').contains('Networks').click()
    cy.contains('Default NAT').should('exist')
  })
})
