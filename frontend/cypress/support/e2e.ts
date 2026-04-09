declare namespace Cypress {
  interface Chainable {
    /** Log in via the real API and store the JWT in localStorage */
    login(username?: string, password?: string): Chainable<void>
    /** Delete a VM by name if it exists (cleanup helper) */
    deleteVMByName(name: string): Chainable<void>
    /** Delete a disk by name if it exists (cleanup helper) */
    deleteDiskByName(name: string): Chainable<void>
    /** Delete a network by name if it exists (cleanup helper) */
    deleteNetworkByName(name: string): Chainable<void>
    /** Delete an image by name if it exists (cleanup helper) */
    deleteImageByName(name: string): Chainable<void>
    /** Get a valid auth token via API */
    apiLogin(username?: string, password?: string): Chainable<string>
    /** Delete an API key by name if it exists */
    deleteAPIKeyByName(name: string): Chainable<void>
    /** Delete an SSH key by name if it exists */
    deleteSSHKeyByName(name: string): Chainable<void>
  }
}

Cypress.Commands.add('apiLogin', (username?: string, password?: string) => {
  const user = username || Cypress.env('username')
  const pass = password || Cypress.env('password')
  return cy
    .request({
      method: 'POST',
      url: '/api/auth/login',
      body: { username: user, password: pass },
      failOnStatusCode: false,
    })
    .then((res) => {
      if (res.status === 200) {
        return res.body.token as string
      }
      throw new Error(`Login failed with status ${res.status}`)
    })
})

Cypress.Commands.add('login', (username?: string, password?: string) => {
  cy.apiLogin(username, password).then((token) => {
    localStorage.setItem('token', token)
  })
})

Cypress.Commands.add('deleteVMByName', (name: string) => {
  cy.apiLogin().then((token) => {
    cy.request({
      method: 'GET',
      url: '/api/vms',
      headers: { Authorization: `Bearer ${token}` },
    }).then((res) => {
      const vm = res.body.find((v: any) => v.name === name)
      if (vm) {
        // Stop first if running
        if (vm.state === 'running') {
          cy.request({
            method: 'POST',
            url: `/api/vms/${vm.id}/stop`,
            headers: { Authorization: `Bearer ${token}` },
            body: { method: 'force' },
            failOnStatusCode: false,
          })
          // Wait for it to stop
          cy.wait(2000)
        }
        cy.request({
          method: 'DELETE',
          url: `/api/vms/${vm.id}`,
          headers: { Authorization: `Bearer ${token}` },
          failOnStatusCode: false,
        })
        // Wait for async deletion to complete
        cy.wait(3000)
      }
    })
  })
})

Cypress.Commands.add('deleteDiskByName', (name: string) => {
  cy.apiLogin().then((token) => {
    cy.request({
      method: 'GET',
      url: '/api/disks',
      headers: { Authorization: `Bearer ${token}` },
    }).then((res) => {
      const disk = res.body.find((d: any) => d.name === name)
      if (disk && !disk.vmId) {
        cy.request({
          method: 'DELETE',
          url: `/api/disks/${disk.id}`,
          headers: { Authorization: `Bearer ${token}` },
          failOnStatusCode: false,
        })
      }
    })
  })
})

Cypress.Commands.add('deleteNetworkByName', (name: string) => {
  cy.apiLogin().then((token) => {
    cy.request({
      method: 'GET',
      url: '/api/networks',
      headers: { Authorization: `Bearer ${token}` },
    }).then((res) => {
      const net = res.body.find((n: any) => n.name === name)
      if (net && !net.isDefault) {
        cy.request({
          method: 'DELETE',
          url: `/api/networks/${net.id}`,
          headers: { Authorization: `Bearer ${token}` },
          failOnStatusCode: false,
        })
      }
    })
  })
})

Cypress.Commands.add('deleteImageByName', (name: string) => {
  cy.apiLogin().then((token) => {
    cy.request({
      method: 'GET',
      url: '/api/images',
      headers: { Authorization: `Bearer ${token}` },
    }).then((res) => {
      const img = res.body.find((i: any) => i.name === name)
      if (img) {
        cy.request({
          method: 'DELETE',
          url: `/api/images/${img.id}`,
          headers: { Authorization: `Bearer ${token}` },
          failOnStatusCode: false,
        })
      }
    })
  })
})

Cypress.Commands.add('deleteAPIKeyByName', (name: string) => {
  cy.apiLogin().then((token) => {
    cy.request({
      method: 'GET',
      url: '/api/auth/keys',
      headers: { Authorization: `Bearer ${token}` },
    }).then((res) => {
      const key = res.body.find((k: any) => k.name === name)
      if (key) {
        cy.request({
          method: 'DELETE',
          url: `/api/auth/keys/${key.id}`,
          headers: { Authorization: `Bearer ${token}` },
          failOnStatusCode: false,
        })
      }
    })
  })
})

Cypress.Commands.add('deleteSSHKeyByName', (name: string) => {
  cy.apiLogin().then((token) => {
    cy.request({
      method: 'GET',
      url: '/api/ssh-keys',
      headers: { Authorization: `Bearer ${token}` },
    }).then((res) => {
      const key = res.body.find((k: any) => k.name === name)
      if (key) {
        cy.request({
          method: 'DELETE',
          url: `/api/ssh-keys/${key.id}`,
          headers: { Authorization: `Bearer ${token}` },
          failOnStatusCode: false,
        })
      }
    })
  })
})

// Prevent Cypress from failing on uncaught exceptions from the app
Cypress.on('uncaught:exception', () => false)
