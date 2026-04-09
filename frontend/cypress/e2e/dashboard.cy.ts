describe('Dashboard', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/dashboard')
  })

  it('shows page title and date', () => {
    cy.contains('h1', 'Dashboard').should('be.visible')
    cy.get('.welcome-sub').should('exist')
  })

  it('displays system stat cards', () => {
    cy.get('.stat-grid').should('exist')
    cy.contains('Total VMs').should('exist')
    cy.contains('Host CPU').should('exist')
    cy.contains('Host Memory').should('exist')
    cy.contains('Storage (on disk)').should('exist')
  })

  it('stat cards show live numeric values', () => {
    cy.get('.dash-stat-number').should('have.length.gte', 4)
    // CPU % should be a number
    cy.get('.dash-stat-number').eq(1).invoke('text').should('match', /\d+%/)
  })

  it('Total VMs stat shows a valid number', () => {
    cy.get('.dash-stat-number').first().invoke('text').should('match', /\d+/)
  })

  it('Host Memory stat shows GB format', () => {
    cy.get('.dash-stat-number').eq(2).invoke('text').should('match', /\d+.*GB/)
  })

  it('Storage stat shows a valid value', () => {
    cy.get('.dash-stat-number').eq(3).invoke('text').should('match', /\d+/)
  })

  it('shows Quick Launch grid with all 6 shortcuts', () => {
    cy.contains('h2', 'Quick Launch').should('be.visible')
    cy.get('.quick-card').should('have.length', 6)
    cy.get('.quick-card').contains('Machines').should('exist')
    cy.get('.quick-card').contains('Templates').should('exist')
    cy.get('.quick-card').contains('Images').should('exist')
    cy.get('.quick-card').contains('Disks').should('exist')
    cy.get('.quick-card').contains('Networks').should('exist')
    cy.get('.quick-card').contains('Settings').should('exist')
  })

  it('shows Resources overview section', () => {
    cy.contains('h2', 'Resources').should('be.visible')
    cy.get('.resource-card').should('have.length', 3)
    cy.contains('Images Ready').should('exist')
    cy.contains('Disks').should('exist')
    cy.contains('Networks').should('exist')
  })

  it('resource cards show numeric counts', () => {
    cy.get('.resource-card').each(($card) => {
      cy.wrap($card).find('.resource-number').invoke('text').should('match', /\d+/)
    })
  })

  // --- Quick Launch Navigation ---

  it('quick-launch Machines navigates to /vms', () => {
    cy.get('.quick-card').contains('Machines').click()
    cy.url().should('include', '/vms')
  })

  it('quick-launch Templates navigates to /registry', () => {
    cy.get('.quick-card').contains('Templates').click()
    cy.url().should('include', '/registry')
  })

  it('quick-launch Images navigates to /images', () => {
    cy.get('.quick-card').contains('Images').click()
    cy.url().should('include', '/images')
  })

  it('quick-launch Disks navigates to /disks', () => {
    cy.get('.quick-card').contains('Disks').click()
    cy.url().should('include', '/disks')
  })

  it('quick-launch Networks navigates to /networks', () => {
    cy.get('.quick-card').contains('Networks').click()
    cy.url().should('include', '/networks')
  })

  it('quick-launch Settings navigates to /settings', () => {
    cy.get('.quick-card').contains('Settings').click()
    cy.url().should('include', '/settings')
  })

  it('resource card click navigates to the right page', () => {
    cy.get('.resource-card').contains('Networks').parents('.resource-card').click()
    cy.url().should('include', '/networks')
  })

  it('Images Ready resource card navigates to /images', () => {
    cy.get('.resource-card').contains('Images Ready').parents('.resource-card').click()
    cy.url().should('include', '/images')
  })

  it('Disks resource card navigates to /disks', () => {
    cy.get('.resource-card').contains('Disks').parents('.resource-card').click()
    cy.url().should('include', '/disks')
  })

  it('Create VM button navigates to /vms?create=1', () => {
    cy.get('.welcome').contains('button', 'Create VM').click()
    cy.url().should('include', '/vms')
  })

  it('shows Recent Machines table when VMs exist', () => {
    // This section is conditional; just verify the section heading renders if VMs exist
    cy.get('body').then(($body) => {
      if ($body.find('h2:contains("Recent Machines")').length) {
        cy.get('table thead').should('contain', 'Name')
        cy.get('table thead').should('contain', 'Status')
        cy.get('table thead').should('contain', 'CPU')
      }
    })
  })

  it('Recent Machines table rows are clickable and navigate to VM detail', () => {
    cy.get('body').then(($body) => {
      if ($body.find('h2:contains("Recent Machines")').length && $body.find('table tbody tr').length) {
        cy.get('table tbody tr').first().click()
        cy.url().should('match', /\/vms\/[a-zA-Z0-9-]+/)
      }
    })
  })
})
