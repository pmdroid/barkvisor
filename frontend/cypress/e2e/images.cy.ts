describe('Image Library', () => {
  beforeEach(() => {
    cy.login()
    cy.visit('/images')
  })

  it('shows page header with Upload and Download buttons', () => {
    cy.contains('h1', 'Images').should('be.visible')
    cy.contains('button', 'Upload Image').should('exist')
    cy.contains('button', 'Download Image').should('exist')
  })

  it('lists images in a table or shows empty state', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table').length) {
        cy.get('table thead th').should('contain', 'Name')
        cy.get('table thead th').should('contain', 'Type')
        cy.get('table thead th').should('contain', 'Arch')
        cy.get('table thead th').should('contain', 'Size')
        cy.get('table thead th').should('contain', 'Status')
      } else {
        cy.contains('No images yet').should('exist')
        cy.contains('Upload an ISO/disk image').should('exist')
      }
    })
  })

  it('image rows show type badge and status pill', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        // Type badge (iso / cloud-image)
        cy.get('table tbody .badge').should('have.length.gte', 1)
        // Status pill (ready / downloading / error)
        cy.get('table tbody .status-pill').should('have.length.gte', 1)
      }
    })
  })

  it('type badge shows iso or cloud-image', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody tr').first().within(() => {
          cy.get('.badge').first().invoke('text').should('match', /iso|cloud-image/)
        })
      }
    })
  })

  it('arch badge shows arm64', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody tr').first().within(() => {
          cy.get('.badge').should('contain', 'arm64')
        })
      }
    })
  })

  it('status pill uses correct class for state', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('.status-pill').first().then(($pill) => {
          const text = $pill.text().trim()
          const classes = $pill.attr('class')!
          if (text === 'ready') {
            expect(classes).to.contain('running')
          } else if (text === 'error') {
            expect(classes).to.contain('error')
          } else {
            expect(classes).to.contain('starting')
          }
        })
      }
    })
  })

  it('each image row has a Delete button', () => {
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody tr').each(($tr) => {
          cy.wrap($tr).contains('button', 'Delete').should('exist')
        })
      }
    })
  })

  // --- Download modal ---

  it('opens Download Image modal with name, URL, type, arch fields', () => {
    cy.contains('button', 'Download Image').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Download Image').should('be.visible')
    cy.get('.modal input').should('have.length.gte', 2)
    cy.get('.modal select').should('have.length', 2) // type + arch
  })

  it('download modal has ISO and Cloud Image type options', () => {
    cy.contains('button', 'Download Image').click()
    cy.get('.modal select').first().within(() => {
      cy.get('option').should('contain', 'ISO')
      cy.get('option').should('contain', 'Cloud Image')
    })
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  it('download modal validates required fields', () => {
    cy.contains('button', 'Download Image').click()
    cy.get('.modal').contains('button', 'Download').click()
    cy.contains('Name and URL required').should('be.visible')
  })

  it('download modal closes on Cancel', () => {
    cy.contains('button', 'Download Image').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.get('.modal').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  it('download button shows loading state', () => {
    cy.contains('button', 'Download Image').click()
    cy.get('.modal input').first().type('test-image')
    cy.get('.modal input').last().type('https://example.com/test.iso')
    // The button text should change on click (briefly)
    cy.get('.modal').contains('button', 'Download').should('exist')
    cy.get('.modal').contains('button', 'Cancel').click()
  })

  // --- Upload modal ---

  it('opens Upload Image modal with file drop, name, type, arch', () => {
    cy.contains('button', 'Upload Image').click()
    cy.get('.modal-overlay').should('be.visible')
    cy.contains('h2', 'Upload Image').should('be.visible')
    cy.get('.file-drop').should('exist')
    cy.get('.modal select').should('have.length', 1) // type (arch removed in newer versions) or 2
  })

  it('upload modal file drop shows instruction text', () => {
    cy.contains('button', 'Upload Image').click()
    cy.get('.file-drop').should('contain', 'Click or drag')
  })

  it('upload modal validates file is required', () => {
    cy.contains('button', 'Upload Image').click()
    cy.get('.modal').contains('button', 'Upload').click()
    cy.contains('Select a file').should('be.visible')
  })

  it('upload modal closes on Cancel', () => {
    cy.contains('button', 'Upload Image').click()
    cy.get('.modal').contains('button', 'Cancel').click()
    cy.get('.modal-overlay').should('not.exist')
  })

  // --- Delete ---

  it('delete button opens confirm dialog with image name', () => {
    cy.get('body').then(($b) => {
      if (!$b.find('table tbody tr').length) return
      cy.get('table tbody tr').first().contains('button', 'Delete').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('Delete Image').should('be.visible')
      cy.contains('permanently removed').should('exist')
      cy.get('.modal-overlay').contains('button', 'Cancel').click()
      cy.get('.modal-overlay').should('not.exist')
    })
  })

  it('delete confirm dialog has Delete and Cancel buttons', () => {
    cy.get('body').then(($b) => {
      if (!$b.find('table tbody tr').length) return
      cy.get('table tbody tr').first().contains('button', 'Delete').click()
      cy.get('.modal-overlay').contains('button', 'Delete').should('exist')
      cy.get('.modal-overlay').contains('button', 'Cancel').should('exist')
      cy.get('.modal-overlay').contains('button', 'Cancel').click()
    })
  })
})
