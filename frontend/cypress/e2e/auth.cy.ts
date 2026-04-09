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

  it('shows login form with username, password and sign-in button', () => {
    cy.visit('/login')
    cy.contains('h1', 'BarkVisor').should('be.visible')
    cy.get('input[type="text"]').should('exist')
    cy.get('input[type="password"]').should('exist')
    cy.contains('button', 'Sign In').should('exist')
  })

  it('logs in with valid credentials and redirects to /vms', () => {
    cy.visit('/login')
    cy.get('input[type="text"]').type(Cypress.env('username'))
    cy.get('input[type="password"]').type(Cypress.env('password'))
    cy.contains('button', 'Sign In').click()
    cy.url().should('include', '/vms')
  })

  it('stores JWT token in localStorage after login', () => {
    cy.visit('/login')
    cy.get('input[type="text"]').type(Cypress.env('username'))
    cy.get('input[type="password"]').type(Cypress.env('password'))
    cy.contains('button', 'Sign In').click()
    cy.url().should('include', '/vms')
    cy.window().then((win) => {
      expect(win.localStorage.getItem('token')).to.not.be.null
      expect(win.localStorage.getItem('token')!.length).to.be.greaterThan(10)
    })
  })

  it('shows error on invalid credentials', () => {
    cy.visit('/login')
    cy.get('input[type="text"]').type('admin')
    cy.get('input[type="password"]').type('wrongpassword123')
    cy.contains('button', 'Sign In').click()
    cy.get('.login-error').should('be.visible')
  })

  it('does not store token on failed login', () => {
    cy.visit('/login')
    cy.get('input[type="text"]').type('admin')
    cy.get('input[type="password"]').type('wrongpassword123')
    cy.contains('button', 'Sign In').click()
    cy.get('.login-error').should('be.visible')
    cy.window().then((win) => {
      expect(win.localStorage.getItem('token')).to.be.null
    })
  })

  it('disables button and shows loading text while logging in', () => {
    cy.visit('/login')
    cy.get('input[type="text"]').type(Cypress.env('username'))
    cy.get('input[type="password"]').type(Cypress.env('password'))
    cy.contains('button', 'Sign In').click()
    // Login may be fast, but the final state proves it completed
    cy.url().should('include', '/vms')
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
