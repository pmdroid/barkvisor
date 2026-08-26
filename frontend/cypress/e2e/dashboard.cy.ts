describe('Dashboard', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/dashboard')
  })

  it('shows page title', () => {
    cy.contains('.ops-toolbar h1', 'Dashboard').should('be.visible')
  })

  it('shows the Home ticker', () => {
    cy.get('.ops-ticker').should('exist')
    cy.get('.ops-ticker').invoke('text').should('match', /running/i)
  })

  it('shows the Home Device list', () => {
    cy.get('.triage-home-dev').should('have.length.gte', 1)
  })

  it('shows triage sections', () => {
    cy.contains('.section-label', 'Needs you').should('exist')
    cy.contains('.section-label', 'Running').should('exist')
    cy.contains('.section-label', 'Stopped').should('exist')
  })

  it('Customize opens the module drawer', () => {
    cy.get('.dash-drawer').should('not.have.class', 'open')
    cy.contains('button', 'Customize').click()
    cy.get('.dash-drawer').should('have.class', 'open')
    cy.contains('Customize Home').should('exist')
    cy.contains('This Device').should('exist')
  })

  it('Create VM button navigates to /vms', () => {
    cy.get('.ops-toolbar').contains('button', 'Create VM').click()
    cy.url().should('include', '/vms')
  })
})
