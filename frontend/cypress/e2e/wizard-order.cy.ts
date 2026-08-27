describe('Create VM wizard order (magazine)', () => {
  beforeEach(() => {
    cy.login()
  })

  function openCreate() {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.get('.mag-frame').should('be.visible')
  }

  it('opens on gallery with 3-step magazine frame', () => {
    openCreate()
    cy.contains('h2', 'What do you want to run?').should('be.visible')
    cy.contains('.mag-step', 'Step 1 of 3').should('be.visible')
    cy.get('.split-rail').should('not.exist')
    cy.get('.mag-shelf').should('exist')
    cy.contains('.mag-custom', 'Use your own image').should('be.visible')
    cy.contains('.mag-card b', 'Windows').should('be.visible')
  })

  it('walks a cloud template through configure and disk', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/templates',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const templates = (res.body as Array<{ slug: string; name: string }>).filter(
          (row) => !['pi-hole', 'onyx'].includes(row.slug),
        )
        if (!templates.length) {
          cy.log('SKIP: no templates')
          return
        }
        const template = templates.find((row) => row.slug === 'debian-cloud') ?? templates[0]

        openCreate()
        cy.contains('.mag-card', template.name).click()
        cy.contains('h2', 'Name it and pick a size').should('be.visible')
        cy.contains('.mag-step', 'Step 2 of 3').should('be.visible')
        cy.get('input').first().should('not.have.value', '')
        cy.get('.mag-flabel').contains('Password').should('not.exist')
        cy.contains('button', 'Next').click()
        cy.contains('h2', 'Disk').should('be.visible')
        cy.contains('.mag-dcard', 'New disk').should('be.visible')
        cy.contains('.mag-dcard', 'Existing disk').should('be.visible')
        cy.contains('.mag-dcard', 'Raw host device').should('be.visible')
        cy.contains('button', 'Create').should('be.visible')
      })
    })
  })

  it('custom image stays on configure until an image is picked', () => {
    openCreate()
    cy.contains('.mag-custom', 'Use your own image').click()
    cy.contains('h2', 'Name it and pick a size').should('be.visible')
    cy.contains('button', 'Next').should('be.disabled')
  })

  it('Windows configure hides the hostname hint', () => {
    openCreate()
    cy.contains('.mag-card b', 'Windows').click()
    cy.contains('h2', 'Set up Windows').should('be.visible')
    cy.get('.mag-hostname').should('not.exist')
  })

  it('existing disk card requires a pick', () => {
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
        openCreate()
        cy.contains('.mag-card', templates[0].name).click()
        cy.contains('button', 'Next').click()
        cy.contains('.mag-dcard', 'Existing disk').click()
        cy.contains('.mag-dcard', 'Existing disk').should('have.class', 'on')
        cy.contains('button', 'Create').should('be.disabled')
      })
    })
  })

  it('light mode paints the magazine frame with a light surface', () => {
    cy.visit('/vms')
    cy.contains('button', 'Light Mode').click()
    cy.contains('button', 'Create VM').click()
    cy.get('.mag-frame').should('be.visible').then(($el) => {
      const bg = getComputedStyle($el[0]).backgroundColor
      const nums = bg.match(/\d+/g)?.map(Number) ?? []
      expect(nums[0] + nums[1] + nums[2], `bg ${bg}`).to.be.greaterThan(500)
    })
  })
})
