describe('Settings / Repositories', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/settings?tab=repositories')
  })

  it('opens the Repositories tab from the query', () => {
    cy.get('.tabs button.active').should('contain', 'Repositories')
    cy.contains('Catalog URLs each Device in this Home syncs').should('be.visible')
    cy.contains('button', 'Add repository').should('exist')
  })

  it('lists repositories with URL and Sync', () => {
    cy.get('table tbody tr').should('have.length.gte', 1)
    cy.get('table thead th').should('contain', 'URL')
    cy.get('table tbody tr').first().within(() => {
      cy.contains('button', 'Sync').should('exist')
    })
  })

  it('built-in repos show built-in badge and no Remove', () => {
    cy.get('table tbody tr').each(($row) => {
      if ($row.find('.badge:contains("built-in")').length) {
        expect($row.find('button:contains("Remove")').length).to.equal(0)
      }
    })
  })

  it('Add repository opens the catalog URL modal', () => {
    cy.contains('button', 'Add repository').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Add Repository').should('be.visible')
    cy.get('.modal-overlay input[placeholder*="catalog.json"]').should('exist')
    cy.get('.type-toggle').should('contain', 'Images')
    cy.get('.type-toggle').should('contain', 'Templates')
  })

  it('add repo modal validates URL is required', () => {
    cy.contains('button', 'Add repository').click()
    cy.get('.modal-overlay').contains('button', 'Add').click()
    cy.contains('URL required').should('be.visible')
  })

  it('add repo modal closes on Cancel', () => {
    cy.contains('button', 'Add repository').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.get('.modal-overlay').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('old /registry URL lands on Settings Repositories', () => {
    cy.visit('/registry')
    cy.url().should('include', '/settings')
    cy.url().should('include', 'tab=repositories')
    cy.get('.tabs button.active').should('contain', 'Repositories')
    cy.contains('h1', 'Settings').should('be.visible')
    cy.contains('h1', 'Repositories').should('not.exist')
  })
})
