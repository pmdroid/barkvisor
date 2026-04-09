describe('Navigation', () => {
  beforeEach(() => {
    cy.login()
  })

  // Sidebar uses <router-link to="..."> which renders as <a href="...">
  const sidebarRoutes = [
    { href: '/dashboard', label: 'Dashboard' },
    { href: '/vms', label: 'Virtual Machines' },
    { href: '/images', label: 'Images' },
    { href: '/disks', label: 'Disks' },
    { href: '/networks', label: 'Networks' },
    { href: '/registry', label: 'Repositories' },
    { href: '/logs', label: 'Logs' },
    { href: '/settings', label: 'Settings' },
  ]

  sidebarRoutes.forEach(({ href }) => {
    it(`navigates to ${href} via sidebar link`, () => {
      cy.visit('/dashboard')
      cy.get(`.sidebar-nav a[href="${href}"]`).click({ force: true })
      cy.url().should('include', href)
    })
  })

  it('highlights the active sidebar link', () => {
    cy.visit('/vms')
    cy.get('.sidebar-nav a[href="/vms"]').should('have.class', 'active')
    // Other links should NOT have active class
    cy.get('.sidebar-nav a[href="/dashboard"]').should('not.have.class', 'active')
  })

  it('updates active link when navigating between pages', () => {
    cy.visit('/vms')
    cy.get('.sidebar-nav a[href="/vms"]').should('have.class', 'active')
    cy.get('.sidebar-nav a[href="/disks"]').click({ force: true })
    cy.get('.sidebar-nav a[href="/disks"]').should('have.class', 'active')
    cy.get('.sidebar-nav a[href="/vms"]').should('not.have.class', 'active')
  })

  it('redirects unknown routes to /dashboard', () => {
    cy.visit('/this-page-does-not-exist')
    cy.url().should('include', '/dashboard')
  })

  it('redirects / to /dashboard', () => {
    cy.visit('/')
    cy.url().should('include', '/dashboard')
  })

  it('sidebar can be expanded and collapsed', () => {
    cy.visit('/dashboard')
    cy.get('.sidebar').should('not.have.class', 'expanded')
    cy.get('.sidebar-toggle').click({ force: true })
    cy.get('.sidebar').should('have.class', 'expanded')
    cy.get('.sidebar-toggle').click({ force: true })
    cy.get('.sidebar').should('not.have.class', 'expanded')
  })

  it('each sidebar link has an icon', () => {
    cy.visit('/dashboard')
    sidebarRoutes.forEach(({ href }) => {
      cy.get(`.sidebar-nav a[href="${href}"] svg`).should('exist')
    })
  })
})
