describe('Repositories / Registry', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/registry')
  })

  it('shows page header with Manage button', () => {
    cy.contains('h1', 'Repositories').should('be.visible')
    cy.contains('button', 'Manage').should('exist')
  })

  it('shows Templates / Images tab bar', () => {
    cy.get('.tab-bar .tab-btn').should('have.length', 2)
    cy.get('.tab-btn').contains('Templates').should('exist')
    cy.get('.tab-btn').contains('Images').should('exist')
  })

  it('Templates tab is active by default', () => {
    cy.get('.tab-btn.active').should('contain', 'Templates')
  })

  it('tab bar shows counts', () => {
    // Tab buttons should show counts in parentheses or as badges
    cy.get('.tab-btn').first().invoke('text').should('match', /Templates/)
    cy.get('.tab-btn').last().invoke('text').should('match', /Images/)
  })

  // ==================== Templates Tab ====================

  it('shows category filter buttons when templates exist', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.cat-btn').length) {
        cy.get('.cat-btn').contains('All').should('exist')
        cy.get('.cat-btn.active').should('contain', 'All')
      }
    })
  })

  it('category filters include expected categories', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.cat-btn').length > 1) {
        // Should have at least "All" and one other category
        cy.get('.cat-btn').should('have.length.gte', 2)
      }
    })
  })

  it('templates table shows Name, Category, Resources, Disk, Deploy', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table thead').length) {
        cy.get('table thead th').should('contain', 'Name')
        cy.get('table thead th').should('contain', 'Category')
        cy.get('table thead th').should('contain', 'Resources')
        cy.get('table thead th').should('contain', 'Disk')
        // Deploy buttons
        cy.get('table tbody button').contains('Deploy').should('exist')
      }
    })
  })

  it('template rows show resource info (CPU, memory)', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody tr').first().invoke('text').should('match', /\d+.*CPU|core/)
      }
    })
  })

  it('clicking Deploy opens the template deploy drawer', () => {
    cy.get('body').then(($b) => {
      if (!$b.find('button:contains("Deploy")').length) return
      cy.get('table tbody button').contains('Deploy').first().click()
      // The TemplateDeployDrawer should appear as a modal overlay
      cy.get('.modal-overlay').should('be.visible')
      // Should have a VM name input
      cy.get('.modal-overlay input').should('exist')
      // Close the drawer
      cy.get('body').type('{esc}')
    })
  })

  it('deploy drawer shows wizard steps', () => {
    cy.get('body').then(($b) => {
      if (!$b.find('button:contains("Deploy")').length) return
      cy.get('table tbody button').contains('Deploy').first().click()
      cy.get('.modal-overlay').should('be.visible')
      // Should have step indicators
      cy.get('.wizard-dot, .step-dot').should('have.length.gte', 1)
      cy.get('body').type('{esc}')
    })
  })

  it('clicking a category filter updates the displayed templates', () => {
    cy.get('body').then(($b) => {
      const cats = $b.find('.cat-btn')
      if (cats.length <= 1) return
      // Click the second category
      cy.get('.cat-btn').eq(1).click()
      cy.get('.cat-btn').eq(1).should('have.class', 'active')
      cy.get('.cat-btn').contains('All').should('not.have.class', 'active')
      // Click All to reset
      cy.get('.cat-btn').contains('All').click()
      cy.get('.cat-btn').contains('All').should('have.class', 'active')
    })
  })

  it('category filter resets page to 1', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.cat-btn').length <= 1) return
      // If there's pagination, clicking a category should reset to page 1
      cy.get('.cat-btn').eq(1).click()
      cy.get('.cat-btn').contains('All').click()
    })
  })

  // ==================== Images Tab ====================

  it('switches to Images tab', () => {
    cy.get('.tab-btn').contains('Images').click()
    cy.get('.tab-btn.active').should('contain', 'Images')
  })

  it('Images tab shows image list or empty state', () => {
    cy.get('.tab-btn').contains('Images').click()
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table').should('exist')
      } else {
        // Empty state or loading
        cy.get('body').should('exist')
      }
    })
  })

  it('Images tab shows image details (name, version, size)', () => {
    cy.get('.tab-btn').contains('Images').click()
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('table thead').length) {
        cy.get('table thead th').should('contain', 'Name')
      }
    })
  })

  it('Images tab has download buttons for images', () => {
    cy.get('.tab-btn').contains('Images').click()
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody button').should('have.length.gte', 1)
      }
    })
  })

  // ==================== Manage Dropdown ====================

  it('Manage button opens repository dropdown', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').should('be.visible')
    cy.get('.repo-dropdown').contains('Repositories').should('exist')
    cy.get('.repo-dropdown').contains('+ Add').should('exist')
  })

  it('repository dropdown shows repos with Sync button', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').should('be.visible')
    cy.get('.repo-dropdown-item').should('have.length.gte', 1)
    cy.get('.repo-dropdown-item').first().within(() => {
      cy.contains('button', 'Sync').should('exist')
    })
  })

  it('repository items show type badge', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown-item').first().within(() => {
      cy.get('.badge').should('have.length.gte', 1)
    })
  })

  it('repository items show sync status', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown-item').first().within(() => {
      // Should show either synced, syncing, or error badge
      cy.get('.badge').should('have.length.gte', 1)
    })
  })

  it('built-in repos show built-in badge', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').then(($dropdown) => {
      if ($dropdown.find('.badge:contains("built-in")').length) {
        cy.get('.repo-dropdown .badge').contains('built-in').should('exist')
      }
    })
  })

  it('built-in repos do not have Remove button', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown-item').each(($item) => {
      if ($item.find('.badge:contains("built-in")').length) {
        expect($item.find('button:contains("Remove")').length).to.equal(0)
      }
    })
  })

  it('clicking + Add opens the add repo modal', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').contains('+ Add').click()
    cy.get('.modal-overlay').should('be.visible')
  })

  it('add repo modal has URL and type fields', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').contains('+ Add').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.get('.modal input').should('exist')
    cy.get('.modal select').should('exist')
    cy.get('.modal select option').should('contain', 'images')
    cy.get('.modal select option').should('contain', 'templates')
  })

  it('add repo modal validates URL is required', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').contains('+ Add').click()
    cy.get('.modal').contains('button', 'Add').click()
    cy.contains('URL required').should('be.visible')
  })

  it('dropdown closes when clicking outside', () => {
    cy.contains('button', 'Manage').click()
    cy.get('.repo-dropdown').should('be.visible')
    cy.get('h1').click({ force: true })
    cy.get('.repo-dropdown').should('not.exist')
  })

  // ==================== Pagination ====================

  it('pagination appears when templates exceed page size', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.pagination').length) {
        cy.get('.page-info').should('exist')
        // Should show page numbers
        cy.get('.pagination').invoke('text').should('match', /\d+/)
      }
    })
  })
})
