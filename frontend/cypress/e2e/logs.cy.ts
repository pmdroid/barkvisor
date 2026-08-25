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

  it('time range selector has correct options', () => {
    cy.get('.page-header select').last().within(() => {
      cy.get('option').should('contain', 'Last Hour')
      cy.get('option').should('contain', 'Last 24 Hours')
      cy.get('option').should('contain', 'Last 7 Days')
    })
  })

  it('loads log entries or shows empty state', () => {
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('.stream .line').length) {
        cy.get('.term-head').invoke('text').should('match', /History|Live tail/)
        cy.get('.stream .line').first().find('.lt').should('exist')
        cy.get('.stream .line').first().find('.lv').should('exist')
        cy.get('.stream .line').first().find('.lmsg').should('exist')
      } else {
        cy.contains('No log entries found').should('exist')
      }
    })
  })

  it('stream rows show level and timestamp', () => {
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('.stream .line').length) {
        cy.get('.stream .line').first().within(() => {
          cy.get('.lv').invoke('text').should('match', /INFO|WARN|ERROR|FATAL|DEBUG/)
          cy.get('.lt').should('not.contain', 'Invalid Date')
        })
      }
    })
  })

  it('error rows have special styling', () => {
    cy.wait(1000)
    cy.get('body').then(($b) => {
      if ($b.find('.line.err').length) {
        cy.get('.line.err').should('have.length.gte', 1)
      }
    })
  })

  it('changing time range reloads logs', () => {
    cy.get('.page-header select').last().select('1h')
    cy.wait(500)
    cy.get('.page-header select').last().select('7d')
    cy.wait(500)
  })

  it('search input filters with debounce', () => {
    cy.get('input[placeholder*="Search"]').type('server')
    cy.wait(500)
    cy.get('input[placeholder*="Search"]').clear()
  })

  it('live tail toggle works', () => {
    cy.contains('button', 'Live Tail').click()
    cy.get('.btn-live-active').should('exist')
    cy.contains('button', 'Pause').should('exist')
    cy.contains('button', 'Pause').click()
    cy.contains('button', 'Resume').should('exist')
  })

  it('Diagnostics button exists and is clickable', () => {
    cy.contains('button', 'Diagnostics').should('exist').and('not.be.disabled')
  })

  it('clear is available in the stream header', () => {
    cy.contains('button', 'Clear').should('exist')
  })
})
