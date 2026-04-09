describe('Disk Management', () => {
  const diskName = 'cypress-test-disk'

  before(() => cy.deleteDiskByName(diskName))
  after(() => cy.deleteDiskByName(diskName))

  beforeEach(() => {
    cy.login()
    cy.visit('/disks')
  })

  it('shows page header and Create Disk button', () => {
    cy.contains('h1', 'Disks').should('be.visible')
    cy.contains('button', 'Create Disk').should('exist')
  })

  it('shows storage summary when disks exist', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.storage-summary').length) {
        cy.contains('Disk Usage').should('exist')
        cy.contains('System Volume').should('exist')
        cy.get('.storage-bar').should('exist')
        cy.get('.storage-legend').should('exist')
        // Legend shows VM disks, Other, Free
        cy.get('.storage-legend').contains('VM disks').should('exist')
        cy.get('.storage-legend').contains('Other').should('exist')
        cy.get('.storage-legend').contains('Free').should('exist')
      }
    })
  })

  it('storage summary shows actual and provisioned sizes', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.storage-summary').length) {
        cy.contains('used on disk').should('exist')
        cy.contains('provisioned').should('exist')
      }
    })
  })

  it('lists disks in a table or shows empty state', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table').length) {
        cy.get('table thead th').should('contain', 'Name')
        cy.get('table thead th').should('contain', 'Format')
        cy.get('table thead th').should('contain', 'Provisioned')
        cy.get('table thead th').should('contain', 'Used on Disk')
        cy.get('table thead th').should('contain', 'VM')
      } else {
        cy.contains('No disks').should('exist')
      }
    })
  })

  it('disk rows show format badge', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody .badge').should('have.length.gte', 1)
        // Format should be qcow2 or raw
        cy.get('table tbody .badge').first().invoke('text').should('match', /qcow2|raw/)
      }
    })
  })

  it('disk rows show usage bar when available', () => {
    cy.get('body').then(($b) => {
      if ($b.find('.usage-bar').length) {
        cy.get('.usage-bar').should('have.length.gte', 1)
        cy.get('.usage-bar-fill').should('have.length.gte', 1)
      }
    })
  })

  it('attached disks show VM link', () => {
    cy.get('body').then(($b) => {
      // Find rows with VM links
      if ($b.find('table tbody tr a').length) {
        cy.get('table tbody tr a').first().should('have.attr', 'href').and('include', '/vms/')
      }
    })
  })

  it('VM link on attached disk navigates to VM detail', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr a').length) {
        cy.get('table tbody tr a').first().click()
        cy.url().should('match', /\/vms\/[a-zA-Z0-9-]+/)
      }
    })
  })

  // --- Create Disk modal ---

  it('opens Create Disk modal with name, size, format fields', () => {
    cy.contains('button', 'Create Disk').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Create Disk').should('be.visible')
    cy.get('.modal input[placeholder="data-disk"]').should('exist')
    cy.get('.modal input[type="number"]').should('exist')
    cy.get('.modal select').should('exist')
    cy.get('.modal select option').should('contain', 'QCOW2')
  })

  it('Create Disk offers QCOW2 and Raw format options', () => {
    cy.contains('button', 'Create Disk').click()
    cy.get('.modal select option').should('contain', 'QCOW2')
    cy.get('.modal select option').should('contain', 'Raw')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('create disk validates name is required', () => {
    cy.contains('button', 'Create Disk').click()
    cy.get('.modal').contains('button', 'Create').click()
    cy.contains('Name required').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('create disk modal can be closed via Cancel', () => {
    cy.contains('button', 'Create Disk').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('creates a new QCOW2 disk', () => {
    cy.contains('button', 'Create Disk').click()
    cy.get('.modal input[placeholder="data-disk"]').type(diskName)
    cy.get('.modal input[type="number"]').clear().type('1')
    cy.get('.modal').contains('button', 'Create').click()
    cy.get('.modal-overlay').should('not.exist')
    cy.contains(diskName).should('exist')
  })

  it('newly created disk shows Unattached badge', () => {
    cy.contains('tr', diskName).within(() => {
      cy.get('.badge').should('contain', 'Unattached')
    })
  })

  it('newly created disk shows qcow2 format badge', () => {
    cy.contains('tr', diskName).within(() => {
      cy.get('.badge').should('contain', 'qcow2')
    })
  })

  it('newly created disk has Resize and Delete buttons', () => {
    cy.contains('tr', diskName).within(() => {
      cy.contains('button', 'Resize').should('exist')
      cy.contains('button', 'Delete').should('exist')
    })
  })

  // --- Resize ---

  it('opens Resize dialog with current size info', () => {
    cy.contains('tr', diskName).contains('button', 'Resize').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Resize Disk').should('be.visible')
    cy.contains(diskName).should('exist')
    cy.contains('Disks can only grow').should('exist')
    cy.get('.modal input[type="number"]').should('exist')
    cy.contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('resizes the disk and shows guest commands', () => {
    cy.contains('tr', diskName).contains('button', 'Resize').click()
    cy.get('.modal input[type="number"]').clear().type('3')
    cy.contains('button', 'Resize').click()

    // After resize, guest commands should be shown
    cy.contains('Disk Resized', { timeout: 10000 }).should('be.visible')
    cy.contains('grow the partition').should('exist')

    // Guest command accordion sections
    cy.get('.guest-cmd-group').should('have.length.gte', 1)
    cy.contains('Ubuntu / Debian').should('exist')
    cy.contains('Alpine Linux').should('exist')

    // Expand a section to see commands
    cy.contains('Ubuntu / Debian').click()
    cy.get('.guest-cmd-body').should('be.visible')
    cy.get('.guest-cmd-body code').should('contain', 'growpart')

    cy.contains('button', 'Done').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  // --- Delete ---

  it('delete button opens confirm dialog', () => {
    cy.get('body').then(($b) => {
      if (!$b.find(`td:contains("${diskName}")`).length) return
      cy.contains('tr', diskName).contains('button', 'Delete').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('Delete Disk').should('be.visible')
      cy.contains(diskName).should('exist')
      cy.contains('permanently removed').should('exist')
      // Cancel
      cy.get('.modal-overlay').contains('button', 'Cancel').click()
      cy.get('.modal-overlay').should('not.exist')
    })
  })

  it('deletes the unattached test disk', () => {
    cy.get('body').then(($b) => {
      if (!$b.find(`td:contains("${diskName}")`).length) return
      cy.contains('tr', diskName).contains('button', 'Delete').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('Delete Disk').should('be.visible')
      cy.get('.modal-overlay').contains('button', 'Delete').click()
      cy.contains(diskName).should('not.exist')
    })
  })
})
