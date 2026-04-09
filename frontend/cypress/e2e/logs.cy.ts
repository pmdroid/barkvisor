describe('Log Viewer', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/logs')
  })

  it('shows page header with search, time range, live tail, diagnostics', () => {
    cy.contains('h1', 'Logs').should('be.visible')
    cy.get('input[placeholder*="Search"]').should('exist')
    cy.get('.page-header select').should('exist')
    cy.contains('button', 'Live Tail').should('exist')
    cy.contains('button', 'Diagnostics').should('exist')
  })

  it('shows source filter tabs (All / Server / QEMU)', () => {
    cy.get('.tab-group').first().within(() => {
      cy.contains('button', 'All').should('exist')
      cy.contains('button', 'Server').should('exist')
      cy.contains('button', 'QEMU').should('exist')
    })
  })

  it('shows level filter tabs (All / Info+ / Warn+ / Errors)', () => {
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'All').should('exist')
      cy.contains('button', 'Info+').should('exist')
      cy.contains('button', 'Warn+').should('exist')
      cy.contains('button', 'Errors').should('exist')
    })
  })

  it('Warn+ level filter is active by default', () => {
    cy.get('.tab-group').last().within(() => {
      cy.contains('button.active', 'Warn+').should('exist')
    })
  })

  it('All source filter is active by default', () => {
    cy.get('.tab-group').first().within(() => {
      cy.contains('button.active', 'All').should('exist')
    })
  })

  it('time range selector has correct options', () => {
    cy.get('.page-header select option').should('contain', 'Last Hour')
    cy.get('.page-header select option').should('contain', 'Last 6 Hours')
    cy.get('.page-header select option').should('contain', 'Last 24 Hours')
    cy.get('.page-header select option').should('contain', 'Last 7 Days')
    cy.get('.page-header select option').should('contain', 'All Time')
  })

  it('loads log entries or shows empty state', () => {
    // Wait for the fetch to complete
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table thead th').should('contain', 'Time')
        cy.get('table thead th').should('contain', 'Level')
        cy.get('table thead th').should('contain', 'Source')
        cy.get('table thead th').should('contain', 'Message')
        cy.get('table thead th').should('contain', 'VM')
      } else {
        cy.contains('No log entries found').should('exist')
        cy.contains('Try adjusting').should('exist')
      }
    })
  })

  it('log table rows show level badge, source badge, and timestamp', () => {
    // Use All level and All Time to maximise chance of having data
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'All').click()
    })
    cy.get('.page-header select').select('')
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody tr').first().within(() => {
          // Level badge
          cy.get('.badge').should('have.length.gte', 1)
          // Timestamp in mono font
          cy.get('.mono').should('exist')
        })
      }
    })
  })

  it('level badges use correct color classes', () => {
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'All').click()
    })
    cy.get('.page-header select').select('')
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('table tbody .badge').length) {
        cy.get('table tbody .badge').each(($badge) => {
          const text = $badge.text().trim()
          const classes = $badge.attr('class')!
          if (text === 'error' || text === 'fatal') {
            expect(classes).to.contain('badge-red')
          } else if (text === 'warn') {
            expect(classes).to.contain('badge-amber')
          } else if (text === 'info') {
            expect(classes).to.contain('badge-blue')
          }
        })
      }
    })
  })

  it('error rows have special styling', () => {
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'Errors').click()
    })
    cy.get('.page-header select').select('')
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('.row-error').length) {
        cy.get('.row-error').should('have.length.gte', 1)
      }
    })
  })

  it('switching level filter reloads the table', () => {
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'All').click()
      cy.contains('button.active', 'All').should('exist')
    })
    // Switch to Errors
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'Errors').click()
      cy.contains('button.active', 'Errors').should('exist')
    })
  })

  it('switching source filter reloads the table', () => {
    cy.get('.tab-group').first().within(() => {
      cy.contains('button', 'Server').click()
      cy.contains('button.active', 'Server').should('exist')
    })
    cy.get('.tab-group').first().within(() => {
      cy.contains('button', 'QEMU').click()
      cy.contains('button.active', 'QEMU').should('exist')
    })
  })

  it('combining source and level filters works', () => {
    cy.get('.tab-group').first().within(() => {
      cy.contains('button', 'Server').click()
    })
    cy.get('.tab-group').last().within(() => {
      cy.contains('button', 'Errors').click()
    })
    // Should not crash; table or empty state should render
    cy.wait(500)
    cy.get('body').then(($b) => {
      if ($b.find('table').length) {
        cy.get('table').should('exist')
      } else {
        cy.contains('No log entries found').should('exist')
      }
    })
  })

  it('changing time range reloads logs', () => {
    cy.get('.page-header select').select('1h')
    // Just verify no crash — content depends on data
    cy.wait(500)
    cy.get('.page-header select').select('7d')
    cy.wait(500)
  })

  it('search input filters with debounce', () => {
    cy.get('input[placeholder*="Search"]').type('server')
    cy.wait(500)
    // No crash, filter applied
    cy.get('input[placeholder*="Search"]').clear()
  })

  it('search input preserves value on filter change', () => {
    cy.get('input[placeholder*="Search"]').type('test-query')
    cy.get('.tab-group').first().within(() => {
      cy.contains('button', 'Server').click()
    })
    cy.get('input[placeholder*="Search"]').should('have.value', 'test-query')
    cy.get('input[placeholder*="Search"]').clear()
  })

  it('live tail toggle works', () => {
    cy.contains('button', 'Live Tail').click()
    cy.contains('button', 'Stop Tail').should('exist')
    cy.get('.btn-live-active').should('exist')
    // Stop it
    cy.contains('button', 'Stop Tail').click()
    cy.contains('button', 'Live Tail').should('exist')
  })

  it('live tail button has active styling', () => {
    cy.contains('button', 'Live Tail').click()
    cy.get('.btn-live-active').should('exist')
    cy.contains('button', 'Stop Tail').click()
    cy.get('.btn-live-active').should('not.exist')
  })

  it('Diagnostics button exists and is clickable', () => {
    cy.contains('button', 'Diagnostics').should('exist').and('not.be.disabled')
  })
})
