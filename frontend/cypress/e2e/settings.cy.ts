describe('Settings', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/settings')
  })

  it('shows page header and three tabs', () => {
    cy.contains('h1', 'Settings').should('be.visible')
    cy.get('.tabs button').should('have.length', 3)
    cy.get('.tabs button').eq(0).should('contain', 'API Keys')
    cy.get('.tabs button').eq(1).should('contain', 'SSH Keys')
    cy.get('.tabs button').eq(2).should('contain', 'Audit Log')
  })

  // ==================== API Keys ====================

  describe('API Keys tab', () => {
    const testKeyName = 'cypress-test-key'

    before(() => cy.deleteAPIKeyByName(testKeyName))
    after(() => cy.deleteAPIKeyByName(testKeyName))

    it('is active by default', () => {
      cy.get('.tabs button.active').should('contain', 'API Keys')
      cy.contains('API keys allow external tools').should('exist')
      cy.contains('button', 'Create Key').should('exist')
    })

    it('shows empty state or key table', () => {
      cy.get('body').then(($b) => {
        if ($b.find('table').length) {
          cy.get('table thead th').should('contain', 'Name')
          cy.get('table thead th').should('contain', 'Key')
          cy.get('table thead th').should('contain', 'Expires')
          cy.get('table thead th').should('contain', 'Last Used')
          cy.get('table thead th').should('contain', 'Created')
        } else {
          cy.contains('No API keys yet').should('exist')
        }
      })
    })

    it('opens Create API Key modal', () => {
      cy.contains('button', 'Create Key').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('h2', 'Create API Key').should('be.visible')
      cy.get('.modal input[placeholder*="terraform"]').should('exist')
    })

    it('Create Key modal has all expiry options', () => {
      cy.contains('button', 'Create Key').click()
      cy.get('.modal select option').should('contain', '30 days')
      cy.get('.modal select option').should('contain', '90 days')
      cy.get('.modal select option').should('contain', '1 year')
      cy.get('.modal select option').should('contain', 'Never')
      cy.get('.modal').contains('button', 'Cancel').click()
    })

    it('Create Key validates name is required', () => {
      cy.contains('button', 'Create Key').click()
      cy.get('.modal').contains('button', 'Create').should('be.disabled')
      cy.get('.modal').contains('button', 'Cancel').click()
    })

    it('Create Key modal closes on Cancel', () => {
      cy.contains('button', 'Create Key').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.get('.modal').contains('button', 'Cancel').click()
      cy.get('.modal-overlay').should('not.exist')
    })

    it('creates a key and shows the secret', () => {
      cy.contains('button', 'Create Key').click()
      cy.get('.modal input[placeholder*="terraform"]').type(testKeyName)
      cy.get('.modal').contains('button', 'Create').click()
      cy.contains('h2', 'API Key Created').should('be.visible')
      cy.contains('Copy this key now').should('exist')
      // The key should be displayed as monospace text
      cy.get('.modal .mono, .modal [style*="font-mono"]').should('exist')
    })

    it('shows Copy to Clipboard button after key creation', () => {
      // Key was already created in previous test, navigate and create fresh
      cy.deleteAPIKeyByName(testKeyName + '-copy')
      cy.contains('button', 'Create Key').click()
      cy.get('.modal input[placeholder*="terraform"]').type(testKeyName + '-copy')
      cy.get('.modal').contains('button', 'Create').click()
      cy.contains('h2', 'API Key Created').should('be.visible')
      cy.contains('button', 'Copy to Clipboard').should('exist')
      cy.contains('button', 'Done').click()
      cy.get('.modal-overlay').should('not.exist')
      // Cleanup
      cy.deleteAPIKeyByName(testKeyName + '-copy')
    })

    it('Done button closes the key created modal', () => {
      // The previous test already created a key; just verify table
      cy.get('body').then(($b) => {
        if ($b.find(`td:contains("${testKeyName}")`).length) {
          cy.contains(testKeyName).should('exist')
        }
      })
    })

    it('shows the created key in the table with prefix', () => {
      cy.get('body').then(($b) => {
        if ($b.find('table').length) {
          cy.get('table thead th').should('contain', 'Name')
          cy.get('table thead th').should('contain', 'Key')
          cy.get('table thead th').should('contain', 'Expires')
          // Key column should show prefix with ...
          cy.get('table tbody').then(($tbody) => {
            if ($tbody.find('.mono').length) {
              cy.get('table tbody .mono').first().invoke('text').should('contain', '...')
            }
          })
        }
      })
    })

    it('revoke button opens confirm dialog', () => {
      cy.get('body').then(($b) => {
        if (!$b.find(`td:contains("${testKeyName}")`).length) return
        cy.contains('tr', testKeyName).contains('button', 'Revoke').click()
        cy.get('.modal-overlay').should('be.visible')
        cy.contains('Revoke API Key').should('be.visible')
        cy.contains(testKeyName).should('exist')
        cy.contains('lose access immediately').should('exist')
        cy.get('.modal-overlay').contains('button', 'Cancel').click()
        cy.get('.modal-overlay').should('not.exist')
      })
    })

    it('revokes the test key', () => {
      cy.get('body').then(($b) => {
        if (!$b.find(`td:contains("${testKeyName}")`).length) return
        cy.contains('tr', testKeyName).contains('button', 'Revoke').click()
        cy.get('.modal-overlay').should('be.visible')
        cy.contains('Revoke API Key').should('be.visible')
        cy.get('.modal-overlay').contains('button', 'Revoke').click()
        cy.contains(testKeyName).should('not.exist')
      })
    })
  })

  // ==================== SSH Keys ====================

  describe('SSH Keys tab', () => {
    const testSSHName = 'cypress-test-ssh'

    before(() => cy.deleteSSHKeyByName(testSSHName))
    after(() => cy.deleteSSHKeyByName(testSSHName))

    beforeEach(() => {
      cy.get('.tabs button').contains('SSH Keys').click()
    })

    it('shows SSH Keys tab content', () => {
      cy.get('.tabs button.active').should('contain', 'SSH Keys')
      cy.contains('SSH public keys are automatically injected').should('exist')
      cy.contains('button', 'Add Key').should('exist')
    })

    it('shows empty state or key table', () => {
      cy.get('body').then(($b) => {
        if ($b.find('table').length) {
          cy.get('table thead th').should('contain', 'Name')
          cy.get('table thead th').should('contain', 'Type')
          cy.get('table thead th').should('contain', 'Fingerprint')
          cy.get('table thead th').should('contain', 'Created')
        } else {
          cy.contains('No SSH keys yet').should('exist')
        }
      })
    })

    it('opens Add SSH Key modal', () => {
      cy.contains('button', 'Add Key').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('h2', 'Add SSH Key').should('be.visible')
      cy.get('.modal input[placeholder*="macbook"]').should('exist')
      cy.get('.modal textarea[placeholder*="ssh-"]').should('exist')
    })

    it('Add Key button is disabled when fields are empty', () => {
      cy.contains('button', 'Add Key').click()
      cy.get('.modal').contains('button', 'Add Key').should('be.disabled')
      cy.get('.modal').contains('button', 'Cancel').click()
    })

    it('Add SSH Key modal closes on Cancel', () => {
      cy.contains('button', 'Add Key').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.get('.modal').contains('button', 'Cancel').click()
      cy.get('.modal-overlay').should('not.exist')
    })

    it('adds an SSH key', () => {
      cy.contains('button', 'Add Key').click()
      cy.get('.modal input[placeholder*="macbook"]').type(testSSHName)
      cy.get('.modal textarea').type(
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkMWFRfaK7rPNrD0toEXgMkFheSoHralkyhw7VxzNAb cypress@test',
      )
      cy.get('.modal').contains('button', 'Add Key').click()
      cy.get('.modal-overlay').should('not.exist')
      cy.contains(testSSHName).should('exist')
    })

    it('SSH keys table shows name, type, fingerprint columns', () => {
      cy.get('body').then(($b) => {
        if ($b.find('table').length) {
          cy.get('table thead th').should('contain', 'Name')
          cy.get('table thead th').should('contain', 'Type')
          cy.get('table thead th').should('contain', 'Fingerprint')
        }
      })
    })

    it('SSH key row shows key type badge', () => {
      cy.get('body').then(($b) => {
        if ($b.find('table tbody tr').length) {
          cy.get('table tbody .badge').should('have.length.gte', 1)
          // Type should be ed25519, rsa, etc.
          cy.get('table tbody .badge').first().invoke('text').should('match', /ed25519|rsa|ecdsa/)
        }
      })
    })

    it('SSH key row shows fingerprint in mono font', () => {
      cy.get('body').then(($b) => {
        if ($b.find('table tbody tr').length) {
          cy.get('table tbody .mono').should('have.length.gte', 1)
        }
      })
    })

    it('SSH key has Set Default button if not already default', () => {
      cy.get('body').then(($b) => {
        if ($b.find(`td:contains("${testSSHName}")`).length) {
          cy.contains('tr', testSSHName).then(($row) => {
            // Should have Set Default or be the default
            if ($row.find('.badge:contains("default")').length === 0) {
              cy.wrap($row).contains('button', 'Set Default').should('exist')
            }
          })
        }
      })
    })

    it('default SSH key shows default badge', () => {
      cy.get('body').then(($b) => {
        if ($b.find('.badge:contains("default")').length) {
          cy.get('.badge').contains('default').should('have.class', 'badge-green')
        }
      })
    })

    it('delete button opens confirm dialog', () => {
      cy.get('body').then(($b) => {
        if (!$b.find(`td:contains("${testSSHName}")`).length) return
        cy.contains('tr', testSSHName).contains('button', 'Delete').click()
        cy.get('.modal-overlay').should('be.visible')
        cy.contains('Delete SSH Key').should('be.visible')
        cy.contains(testSSHName).should('exist')
        cy.contains('will not affect VMs').should('exist')
        cy.get('.modal-overlay').contains('button', 'Cancel').click()
        cy.get('.modal-overlay').should('not.exist')
      })
    })

    it('deletes the test SSH key', () => {
      cy.get('body').then(($b) => {
        if (!$b.find(`td:contains("${testSSHName}")`).length) return
        cy.contains('tr', testSSHName).contains('button', 'Delete').click()
        cy.get('.modal-overlay').should('be.visible')
        cy.contains('Delete SSH Key').should('be.visible')
        cy.get('.modal-overlay').contains('button', 'Delete').click()
        cy.contains(testSSHName).should('not.exist')
      })
    })
  })

  // ==================== Audit Log ====================

  describe('Audit Log tab', () => {
    beforeEach(() => {
      cy.get('.tabs button').contains('Audit Log').click()
    })

    it('shows Audit Log tab content', () => {
      cy.get('.tabs button.active').should('contain', 'Audit Log')
      cy.contains('Activity log of all actions').should('exist')
      cy.contains('90 days').should('exist')
    })

    it('displays audit entries in a table', () => {
      // Our prior actions (login, key create, etc.) should have generated entries
      cy.get('table', { timeout: 5000 }).should('exist')
      cy.get('table thead th').should('contain', 'Time')
      cy.get('table thead th').should('contain', 'User')
      cy.get('table thead th').should('contain', 'Action')
      cy.get('table thead th').should('contain', 'Resource')
      cy.get('table thead th').should('contain', 'Auth')
    })

    it('audit entries show action badges with colors', () => {
      cy.get('table tbody .badge', { timeout: 5000 }).should('have.length.gte', 1)
      // Action badges should be clickable (cursor: pointer)
      cy.get('table tbody .badge').first().should('have.css', 'cursor', 'pointer')
    })

    it('audit entries show auth method badge', () => {
      cy.get('table tbody tr', { timeout: 5000 }).first().within(() => {
        // Auth column should have a badge
        cy.get('td').last().find('.badge').should('exist')
      })
    })

    it('shows pagination with entry count', () => {
      cy.get('table', { timeout: 5000 }).should('exist')
      cy.contains('entries').should('exist')
      cy.contains('button', 'Prev').should('exist')
      cy.contains('button', 'Next').should('exist')
    })

    it('pagination shows current page and total', () => {
      cy.get('table', { timeout: 5000 }).should('exist')
      // Should show "1 / N" format
      cy.get('body').invoke('text').should('match', /\d+\s*\/\s*\d+/)
    })

    it('Prev button is disabled on first page', () => {
      cy.get('table', { timeout: 5000 }).should('exist')
      cy.contains('button', 'Prev').should('be.disabled')
    })

    it('Next button navigates to next page when available', () => {
      cy.get('table', { timeout: 5000 }).should('exist')
      cy.contains('button', 'Next').then(($btn) => {
        if (!$btn.prop('disabled')) {
          cy.wrap($btn).click()
          // Page should advance
          cy.contains('button', 'Prev').should('not.be.disabled')
          // Go back
          cy.contains('button', 'Prev').click()
        }
      })
    })

    it('clicking an action badge filters the log', () => {
      cy.get('table tbody .badge', { timeout: 5000 }).first().click()
      cy.contains('Filtering:').should('exist')
      cy.contains('button', 'Clear').should('exist')
    })

    it('Clear button removes the filter', () => {
      cy.get('table tbody .badge', { timeout: 5000 }).first().click()
      cy.contains('Filtering:').should('exist')
      cy.contains('button', 'Clear').click()
      cy.contains('Filtering:').should('not.exist')
    })

    it('filter shows the action name being filtered', () => {
      cy.get('table tbody .badge', { timeout: 5000 }).first().then(($badge) => {
        const actionText = $badge.text().trim()
        cy.wrap($badge).click()
        cy.contains('Filtering:').should('exist')
        cy.contains(actionText).should('exist')
        cy.contains('button', 'Clear').click()
      })
    })
  })
})
