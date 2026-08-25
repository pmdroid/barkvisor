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

  it('shows the Device list', () => {
    cy.get('.ops-dev').should('have.length.gte', 1)
  })

  it('selecting a Device row marks it selected', () => {
    cy.get('.ops-dev').first().click()
    cy.get('.ops-dev').first().should('have.class', 'selected')
  })

  it('shows the workload board columns', () => {
    cy.contains('.dash-col-head', 'Running').should('exist')
    cy.contains('.dash-col-head', 'Failed').should('exist')
    cy.contains('.dash-col-head', 'Stopped').should('exist')
  })

  it('Create VM button navigates to /vms', () => {
    cy.get('.ops-toolbar').contains('button', 'Create VM').click()
    cy.url().should('include', '/vms')
  })
})
