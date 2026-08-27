describe('Authentication', () => {
  beforeEach(() => {
    localStorage.removeItem('token')
  })

  it('redirects unauthenticated users to login', () => {
    cy.visit('/vms')
    cy.url().should('include', '/login')
  })

  it('redirects all protected routes to login', () => {
    const routes = ['/dashboard', '/vms', '/images', '/disks', '/networks', '/registry', '/logs', '/settings']
    routes.forEach((route) => {
      cy.visit(route)
      cy.url().should('include', '/login')
    })
  })

  it('shows passkey sign-in', () => {
    cy.visit('/login')
    cy.contains('h1', 'BarkVisor').should('be.visible')
    cy.get('input[type="password"]').should('not.exist')
    cy.contains('button', 'Sign in with passkey').should('be.visible')
  })

  it('logs in via API and lands on /vms', () => {
    cy.login()
    cy.visit('/vms')
    cy.url().should('include', '/vms')
  })

  it('stores JWT token in localStorage after API login', () => {
    cy.login()
    cy.visit('/vms')
    cy.window().then((win) => {
      expect(win.localStorage.getItem('token')).to.not.be.null
      expect(win.localStorage.getItem('token')!.length).to.be.greaterThan(10)
    })
  })

  it('logs out via sidebar button', () => {
    cy.login()
    cy.visit('/dashboard')
    cy.contains('Dashboard').should('be.visible')
    cy.get('button[title="Logout"]').click({ force: true })
    cy.url().should('include', '/login')
    cy.window().then((win) => {
      expect(win.localStorage.getItem('token')).to.be.null
    })
  })

  it('expired / cleared token redirects to login on navigation', () => {
    cy.login()
    cy.visit('/dashboard')
    cy.contains('Dashboard').should('be.visible')
    cy.window().then((win) => win.localStorage.removeItem('token'))
    cy.visit('/vms')
    cy.url().should('include', '/login')
  })

  it('persists session across page reload', () => {
    cy.login()
    cy.visit('/vms')
    cy.contains('h1', 'Virtual Machines').should('be.visible')
    cy.reload()
    cy.url().should('include', '/vms')
    cy.contains('h1', 'Virtual Machines').should('be.visible')
  })

  it('API returns 401 for unauthenticated requests', () => {
    cy.request({
      url: '/api/vms',
      failOnStatusCode: false,
    }).then((res) => {
      expect(res.status).to.equal(401)
    })
  })

  it('API returns 401 for invalid token', () => {
    cy.request({
      url: '/api/vms',
      headers: { Authorization: 'Bearer invalid-token-here' },
      failOnStatusCode: false,
    }).then((res) => {
      expect(res.status).to.equal(401)
    })
  })
})
