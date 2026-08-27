describe('Create VM wizard order (magazine)', () => {
  beforeEach(() => {
    cy.login()
  })

  it('opens on gallery with 3-step magazine frame', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.get('.mag-frame').should('be.visible')
    cy.contains('h2', 'What do you want to run?').should('be.visible')
    cy.contains('.mag-step', 'Step 1 of 3').should('be.visible')
    cy.get('.split-rail').should('not.exist')
    cy.get('.mag-shelf').should('exist')
    cy.contains('.mag-custom', 'Use your own image').should('be.visible')
  })

  it('walks gallery to configure to disk', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/templates',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const templates = res.body as Array<{ slug: string; name: string }>
        if (!templates.length) {
          cy.log('SKIP: no templates')
          return
        }
        const template = templates[0]

        cy.visit('/vms')
        cy.contains('button', 'Create VM').click()
        cy.contains('.mag-card', template.name).click()
        cy.contains('h2', 'Name it and pick a size').should('be.visible')
        cy.contains('.mag-step', 'Step 2 of 3').should('be.visible')
        cy.get('input').first().should('not.have.value', '')
        cy.contains('button', 'Next').click()
        cy.contains('h2', 'Disk').should('be.visible')
        cy.contains('button', 'Create').should('be.visible')
      })
    })
  })
})
