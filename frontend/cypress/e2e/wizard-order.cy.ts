describe('Create VM wizard order (PAS-182)', () => {
  beforeEach(() => {
    cy.login()
  })

  it('opens on Basics with no Device picker or arch lecture', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.contains('h2', 'Create Virtual Machine').should('be.visible')
    cy.get('.wizard-dot').should('have.length', 7)
    cy.get('.wizard-dot.active').should('contain', '1')
    cy.contains('h3', 'Basics').should('be.visible')
    cy.get('.device-picker').should('not.exist')
    cy.contains('device arch').should('not.exist')
    cy.contains('Architecture details').should('not.exist')
    cy.contains('Recommended').should('not.exist')
  })

  it('Windows card is selectable and has no device-arch badge', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.get('.os-card').contains('Windows').parent('.os-card').should('not.have.class', 'disabled')
    cy.get('.os-card').contains('Windows').parent('.os-card').find('.os-soon').should('not.exist')
    cy.get('.os-card').contains('Windows').click()
    cy.get('.os-card').contains('Windows').parent('.os-card').should('have.class', 'selected')
  })

  it('walks Basics → Image → Place → Hardware', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/images',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const images = (res.body as Array<{ id: string; name: string; imageType: string; status: string }>)
          .filter((i) => i.status === 'ready')
        const iso = images.find((i) => i.imageType === 'iso')
        const cloud = images.find((i) => i.imageType === 'cloud-image')
        const image = iso || cloud
        if (!image) {
          cy.log('SKIP: no ready Home Library image')
          return
        }

        cy.visit('/vms')
        cy.contains('button', 'Create VM').click()
        cy.contains('h3', 'Basics').should('be.visible')
        cy.get('input[placeholder="my-vm"]').type('wizard-order-vm')
        cy.contains('button', 'Next').click()

        cy.contains('h3', 'Image').should('be.visible')
        cy.get('.device-picker').should('not.exist')
        if (!iso && cloud) {
          cy.contains('button', 'Cloud Image').click()
        }
        cy.get('select').then(($selects) => {
          const imageSelect = $selects.filter(':has(option:contains("Select an image"))')
          const match = [...imageSelect.find('option')].find((opt) => {
            const value = opt.getAttribute('value') || ''
            return value === image.id || value.includes(image.id) || (opt.textContent || '').includes(image.name)
          })
          cy.wrap(imageSelect).select(match?.getAttribute('value') || image.id)
        })
        cy.contains('button', 'Next').click()

        cy.contains('h3', 'Place').should('be.visible')
        cy.get('.device-picker').should('exist')
        cy.contains('button', 'Next').click()

        cy.contains('h3', 'Hardware').should('be.visible')
        cy.contains('CPU Cores').should('exist')
        cy.contains('Architecture details').should('exist')
        cy.get('.arch-details').should('not.have.attr', 'open')
      })
    })
  })
})
