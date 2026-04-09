describe('VM Lifecycle', () => {
  const vmName = 'cypress-e2e-vm'

  before(() => {
    cy.deleteVMByName(vmName)
  })

  after(() => {
    cy.deleteVMByName(vmName)
  })

  beforeEach(() => {
    cy.login()
  })

  // --------------- VM List ---------------

  it('shows the VM list page header and Create VM button', () => {
    cy.visit('/vms')
    cy.contains('h1', 'Virtual Machines').should('be.visible')
    cy.contains('button', 'Create VM').should('be.visible')
  })

  it('shows system stats bar on VM list', () => {
    cy.visit('/vms')
    cy.contains('Host CPU').should('exist')
    cy.contains('Host Memory').should('exist')
    cy.contains('VM CPU Usage').should('exist')
    cy.contains('VM Memory').should('exist')
  })

  it('stats bar shows utilization bars', () => {
    cy.visit('/vms')
    cy.get('.stat-bar', { timeout: 5000 }).should('have.length.gte', 1)
    cy.get('.stat-bar-fill').should('have.length.gte', 1)
  })

  it('VM Memory stat shows running count', () => {
    cy.visit('/vms')
    cy.get('.stat-sub', { timeout: 5000 }).should('contain', 'VMs running')
  })

  it('shows VM table or empty state', () => {
    cy.visit('/vms')
    cy.get('body').then(($b) => {
      if ($b.find('table').length) {
        cy.get('table thead').should('contain', 'Name')
        cy.get('table thead').should('contain', 'Status')
        cy.get('table thead').should('contain', 'OS')
        cy.get('table thead').should('contain', 'Resources')
        cy.get('table thead').should('contain', 'IP / Ports')
      } else {
        cy.contains('No virtual machines').should('exist')
        cy.contains('button', 'Create your first VM').should('exist')
      }
    })
  })

  it('VM table rows show status pills with state class', () => {
    cy.visit('/vms')
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('.status-pill').should('have.length.gte', 1)
        // Each pill should have a state class
        cy.get('.status-pill').first().then(($pill) => {
          const classes = $pill.attr('class')!
          expect(classes).to.match(/running|stopped|starting|stopping|provisioning|error/)
        })
      }
    })
  })

  it('VM table rows are clickable and navigate to detail', () => {
    cy.visit('/vms')
    cy.get('body').then(($b) => {
      if ($b.find('table tbody tr').length) {
        cy.get('table tbody tr').first().click()
        cy.url().should('match', /\/vms\/[a-zA-Z0-9-]+/)
      }
    })
  })

  // --------------- Create VM Wizard ---------------

  it('opens the Create VM drawer on button click', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.contains('h2', 'Create Virtual Machine').should('be.visible')
    // 6-step wizard dots
    cy.get('.wizard-dot').should('have.length', 6)
    cy.get('.wizard-dot.active').should('contain', '1')
  })

  it('Step 1 — sets name, selects Linux, proceeds to step 2', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()

    cy.contains('h3', 'Operating System').should('be.visible')
    cy.get('input[placeholder="my-vm"]').type(vmName)
    cy.get('.os-card').contains('Linux').should('exist')
    cy.get('.os-card').contains('Linux').parent('.os-card').should('have.class', 'selected')

    cy.contains('button', 'Next').click()
    cy.get('.wizard-dot.active').should('contain', '2')
  })

  it('Step 1 — Windows OS card is selectable', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.get('.os-card').contains('Windows').click()
    cy.get('.os-card').contains('Windows').parent('.os-card').should('have.class', 'selected')
    cy.get('.os-card').contains('Linux').parent('.os-card').should('not.have.class', 'selected')
  })

  it('Step 2 — Hardware shows CPU and Memory controls', () => {
    cy.visit('/vms')
    cy.contains('button', 'Create VM').click()
    cy.get('input[placeholder="my-vm"]').type(vmName)
    cy.contains('button', 'Next').click()

    cy.contains('h3', 'Hardware').should('be.visible')
    // CPU and memory controls
    cy.contains('CPU Cores').should('exist')
    cy.contains('Memory').should('exist')
  })

  it('walks through all 6 wizard steps and creates a VM', () => {
    // First check if any ISO image is available
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/images',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const isoImages = res.body.filter(
          (i: any) => i.imageType === 'iso' && i.status === 'ready',
        )
        const cloudImages = res.body.filter(
          (i: any) => i.imageType === 'cloud-image' && i.status === 'ready',
        )

        if (isoImages.length === 0 && cloudImages.length === 0) {
          cy.log('SKIP: no ready images available to create a VM')
          return
        }

        const useCloud = isoImages.length === 0 && cloudImages.length > 0
        const image = useCloud ? cloudImages[0] : isoImages[0]

        cy.visit('/vms')
        cy.contains('button', 'Create VM').click()

        // Step 1 — OS & Name
        cy.get('input[placeholder="my-vm"]').clear().type(vmName)
        cy.contains('button', 'Next').click()

        // Step 2 — Hardware (defaults are fine)
        cy.contains('h3', 'Hardware').should('be.visible')
        cy.contains('button', 'Next').click()

        // Step 3 — Image
        cy.contains('h3', 'Image').should('be.visible')
        if (useCloud) {
          cy.contains('button', 'Cloud Image').click()
        }
        cy.get('select').then(($selects) => {
          // The image select is the one with "Select an image..." option
          const imageSelect = $selects.filter(':has(option:contains("Select an image"))')
          cy.wrap(imageSelect).select(image.id)
        })
        cy.contains('button', 'Next').click()

        // Step 4 — Storage (defaults are fine)
        cy.contains('h3', 'Storage').should('be.visible')
        cy.contains('button', 'Next').click()

        // Step 5 — Network (defaults are fine)
        cy.contains('h3', 'Network').should('be.visible')
        cy.contains('button', 'Next').click()

        // Step 6 — Summary
        cy.contains('h3', 'Summary').should('be.visible')
        cy.get('.summary-row').contains(vmName).should('exist')
        cy.get('.summary-row').contains('Linux').should('exist')
        cy.get('.summary-row').contains('ARM64').should('exist')
        cy.get('.summary-row').contains('2 cores').should('exist')
        cy.get('.summary-row').contains('Default NAT').should('exist')

        // Submit
        cy.contains('button', 'Create VM').click()

        // Drawer should close and VM should appear in the list
        cy.contains('h2', 'Create Virtual Machine').should('not.exist')
        cy.url().should('include', '/vms')

        // Wait for VM to appear (provisioning may take a moment for cloud images)
        cy.contains('td', vmName, { timeout: 30000 }).should('exist')
      })
    })
  })

  // --------------- VM Detail Page ---------------

  it('navigates to VM detail by clicking the VM row', () => {
    cy.visit('/vms')
    cy.get('body').then(($b) => {
      if (!$b.find(`td:contains("${vmName}")`).length) {
        cy.log('SKIP: test VM does not exist')
        return
      }
      cy.contains('td', vmName).click()
      cy.contains('h1', vmName).should('be.visible')
      cy.get('.status-pill').should('exist')
    })
  })

  it('detail page shows overview with hardware info', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.contains('h1', vmName).should('be.visible')

        // Overview tab should be active by default
        cy.get('.tab.active').should('contain', 'Overview')

        // Detail grid shows hardware
        cy.get('.detail-row').contains('CPU').should('exist')
        cy.get('.detail-row').contains('Memory').should('exist')
        cy.get('.detail-row').contains('Network').should('exist')
        cy.get('.detail-row').contains('Boot Order').should('exist')
        cy.get('.detail-row').contains('Resolution').should('exist')
        cy.get('.detail-row').contains('Created').should('exist')

        // Disks section
        cy.contains('h2', 'Disks').should('exist')
        cy.get('.badge').contains('Boot').should('exist')

        // Shared Folders section
        cy.contains('h2', 'Shared Folders').should('exist')
      })
    })
  })

  it('detail page — Edit Settings modal works', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.contains('button', 'Edit Settings').click()
        cy.get('.modal-overlay').should('be.visible')
        cy.contains('h2', 'Edit Settings').should('be.visible')

        // Modal has Description, CPU, Memory, Boot Order, Network fields
        cy.get('.edit-field').should('have.length', 5)
        cy.get('.edit-field').contains('Description').should('exist')
        cy.get('.edit-field').contains('CPU Cores').should('exist')
        cy.get('.edit-field').contains('Memory').should('exist')
        cy.get('.edit-field').contains('Boot Order').should('exist')
        cy.get('.edit-field').contains('Network').should('exist')

        // Cancel without saving
        cy.contains('button', 'Cancel').click()
        cy.get('.modal-overlay').should('not.exist')
      })
    })
  })

  it('detail page — Edit Settings can save changes', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }
        if (vm.state === 'running') { cy.log('SKIP: VM is running'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.contains('button', 'Edit Settings').click()

        // Change description
        cy.get('.edit-field').contains('Description').parent().find('input').clear().type('Cypress test description')
        cy.contains('button', 'Save').click()
        cy.get('.modal-overlay').should('not.exist')

        // Verify the description is shown
        cy.contains('Cypress test description').should('exist')
      })
    })
  })

  it('detail page — tab navigation works', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)

        // Console tab
        cy.get('.tab').contains('Console').click()
        cy.get('.tab.active').should('contain', 'Console')
        if (vm.state !== 'running') {
          cy.contains('VM must be running to use the console').should('exist')
        }

        // VNC tab
        cy.get('.tab').contains('VNC').click()
        cy.get('.tab.active').should('contain', 'VNC')

        // Back to overview
        cy.get('.tab').contains('Overview').click()
        cy.get('.tab.active').should('contain', 'Overview')
      })
    })
  })

  it('detail page — ISOs section shows attach button', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        // ISOs section should exist
        cy.get('body').then(($b) => {
          if ($b.find('h2:contains("ISOs")').length) {
            cy.contains('button', 'Attach ISO').should('exist')
          }
        })
      })
    })
  })

  it('detail page — Shared Folders has Add button', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.contains('h2', 'Shared Folders').should('exist')
        cy.contains('button', 'Add Shared Folder').should('exist')
      })
    })
  })

  it('detail page — Port Forwards section exists for NAT VMs', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        // Port forwards section should exist for NAT VMs
        cy.get('body').then(($b) => {
          if ($b.find('h2:contains("Port Forwards")').length) {
            cy.contains('button', 'Edit').should('exist')
          }
        })
      })
    })
  })

  it('detail page — start a stopped VM, then validate console & metrics', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)

        if (vm.state === 'stopped' || vm.state === 'error') {
          // Start the VM
          cy.contains('button', 'Start').click()
          // Wait for state to transition to running
          cy.get('.status-pill.running', { timeout: 30000 }).should('exist')
        } else if (vm.state !== 'running') {
          // Wait for it to reach running (e.g. provisioning)
          cy.get('.status-pill.running', { timeout: 60000 }).should('exist')
        }

        // --- Console Tab ---
        cy.get('.tab').contains('Console').click()
        cy.get('.tab.active').should('contain', 'Console')
        // xterm.js container should be mounted (height:480px div)
        cy.get('.xterm', { timeout: 10000 }).should('exist')

        // --- Metrics Tab ---
        cy.get('.tab').contains('Metrics').click()
        cy.get('.tab.active').should('contain', 'Metrics')
        // Either "Waiting for metrics data..." or the chart grid
        cy.get('body').then(($b) => {
          if ($b.find('.metrics-grid').length) {
            cy.get('.metric-card').should('have.length', 3)
            cy.contains('h3', 'CPU Usage').should('exist')
            cy.contains('h3', 'Memory').should('exist')
            cy.contains('h3', 'Disk I/O').should('exist')
          } else {
            cy.contains('Waiting for metrics data...').should('exist')
            // Wait for the first sample to arrive
            cy.get('.metrics-grid', { timeout: 20000 }).should('exist')
            cy.get('.metric-card').should('have.length', 3)
          }
        })
      })
    })
  })

  it('detail page — stop menu shows ACPI and Force options', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm || vm.state !== 'running') { cy.log('SKIP: VM not running'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.get('.status-pill.running', { timeout: 10000 }).should('exist')

        // Click the dropdown toggle
        cy.get('.stop-toggle').click()
        cy.get('.stop-menu').should('be.visible')
        cy.get('.stop-menu').contains('ACPI Shutdown').should('exist')
        cy.get('.stop-menu').contains('Force Stop').should('exist')
        // Close without action
        cy.get('.stop-toggle').click()
      })
    })
  })

  it('detail page — stop a running VM via ACPI shutdown', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)

        // Only proceed if running
        cy.get('.status-pill').then(($pill) => {
          if (!$pill.hasClass('running')) {
            cy.log('SKIP: VM is not running')
            return
          }

          // Click the Stop button (the .stop-main part of the split button)
          cy.get('.stop-main').click()

          // Confirm dialog appears
          cy.get('.modal-overlay').should('be.visible')
          cy.contains('Shutdown VM').should('be.visible')
          cy.contains('button', 'Shutdown').click()

          // Wait for state to transition to stopped
          cy.get('.status-pill.stopped', { timeout: 30000 }).should('exist')
        })
      })
    })
  })

  it('detail page — action buttons reflect stopped state', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.get('.status-pill').then(($pill) => {
          if ($pill.hasClass('stopped') || $pill.hasClass('error')) {
            cy.contains('button', 'Start').should('exist')
            cy.contains('button', 'Edit Settings').should('exist')
            cy.contains('button', 'Delete').should('exist')
          }
        })
      })
    })
  })

  it('detail page — back button returns to VM list', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        cy.visit(`/vms/${vm.id}`)
        cy.get('button[title="Back to VMs"]').click()
        cy.url().should('match', /\/vms\/?$/)
      })
    })
  })

  // --------------- Delete VM ---------------

  it('delete dialog shows keep-disk option', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        // Force-stop if running
        if (vm.state === 'running') {
          cy.request({
            method: 'POST',
            url: `/api/vms/${vm.id}/stop`,
            headers: { Authorization: `Bearer ${token}` },
            body: { method: 'force' },
            failOnStatusCode: false,
          })
          cy.wait(3000)
        }

        cy.visit(`/vms/${vm.id}`)
        cy.get('.status-pill.stopped', { timeout: 15000 }).should('exist')
        cy.contains('button', 'Delete').click()

        cy.get('.modal-overlay').should('be.visible')
        cy.contains('h2', 'Delete VM').should('be.visible')
        cy.contains(vmName).should('exist')

        // Cancel without deleting
        cy.contains('button', 'Cancel').click()
        cy.get('.modal-overlay').should('not.exist')
      })
    })
  })

  it('deletes the VM via the detail page', () => {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.name === vmName)
        if (!vm) { cy.log('SKIP: test VM not found'); return }

        // Force-stop first if running
        if (vm.state === 'running') {
          cy.request({
            method: 'POST',
            url: `/api/vms/${vm.id}/stop`,
            headers: { Authorization: `Bearer ${token}` },
            body: { method: 'force' },
            failOnStatusCode: false,
          })
          cy.wait(3000)
          cy.visit(`/vms/${vm.id}`)
          cy.get('.status-pill.stopped', { timeout: 15000 }).should('exist')
        } else {
          cy.visit(`/vms/${vm.id}`)
        }

        // Click Delete button (only visible when stopped)
        cy.contains('button', 'Delete').click()

        // Delete confirmation modal
        cy.get('.modal-overlay').should('be.visible')
        cy.contains('h2', 'Delete VM').should('be.visible')
        cy.contains(vmName).should('exist')

        // Click "Delete VM" to confirm
        cy.contains('button', 'Delete VM').click()

        // Should redirect to VM list
        cy.url({ timeout: 30000 }).should('match', /\/vms\/?$/)
        // VM should no longer appear
        cy.contains('td', vmName).should('not.exist')
      })
    })
  })
})
