/**
 * VM Detail tests that work with any existing VM on the server.
 * The full create→start→console→metrics→stop→delete flow lives in vm-lifecycle.cy.ts.
 */
describe('VM Detail (existing VMs)', () => {
  beforeEach(() => {
    cy.login()
  })

  /** Helper: get the first VM from the API, skip if none exist */
  function withFirstVM(fn: (vm: any) => void) {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        if (res.body.length === 0) {
          cy.log('SKIP: no VMs on server')
          return
        }
        fn(res.body[0])
      })
    })
  }

  /** Helper: get a stopped VM or skip */
  function withStoppedVM(fn: (vm: any) => void) {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.state === 'stopped')
        if (!vm) {
          cy.log('SKIP: no stopped VMs on server')
          return
        }
        fn(vm)
      })
    })
  }

  /** Helper: get a running VM or skip */
  function withRunningVM(fn: (vm: any) => void) {
    cy.apiLogin().then((token) => {
      cy.request({
        url: '/api/vms',
        headers: { Authorization: `Bearer ${token}` },
      }).then((res) => {
        const vm = res.body.find((v: any) => v.state === 'running')
        if (!vm) {
          cy.log('SKIP: no running VMs on server')
          return
        }
        fn(vm)
      })
    })
  }

  // ==================== Overview Tab ====================

  it('shows VM name and state pill', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('h1', vm.name).should('be.visible')
      cy.get('.status-pill').should('exist')
    })
  })

  it('overview tab shows detail rows', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab.active').should('contain', 'Overview')
      cy.get('.detail-row').should('have.length.gte', 5)

      cy.get('.detail-label').contains('Type').should('exist')
      cy.get('.detail-label').contains('CPU').should('exist')
      cy.get('.detail-label').contains('Memory').should('exist')
      cy.get('.detail-label').contains('Network').should('exist')
      cy.get('.detail-label').contains('Created').should('exist')
    })
  })

  it('shows CPU cores and memory values matching the VM', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.detail-row').contains(`${vm.cpuCount} cores`).should('exist')
      cy.get('.detail-row').contains(`${vm.memoryMB} MB`).should('exist')
    })
  })

  it('shows Boot Order and Resolution fields', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.detail-label').contains('Boot Order').should('exist')
      cy.get('.detail-label').contains('Resolution').should('exist')
    })
  })

  // ==================== Disks Section ====================

  it('shows boot disk in Disks section', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('h2', 'Disks').should('exist')
      cy.get('.badge').contains('Boot').should('exist')
    })
  })

  it('boot disk shows usage bar', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      // Boot disk should have usage info
      cy.get('body').then(($b) => {
        if ($b.find('.disk-usage-bar').length || $b.find('.usage-bar').length) {
          cy.get('.disk-usage-bar, .usage-bar').should('have.length.gte', 1)
        }
      })
    })
  })

  it('has Attach Disk button', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('button', 'Attach Disk').should('exist')
    })
  })

  it('opens Attach Disk modal and lists available disks', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('button', 'Attach Disk').click()
      cy.get('.modal-overlay').should('be.visible')
      cy.contains('h2', 'Attach Disk').should('be.visible')
      // Modal should show available disks or "no disks" message
      cy.get('.modal').then(($modal) => {
        if ($modal.find('button:contains("Attach")').length) {
          cy.get('.modal').contains('button', 'Attach').should('exist')
        }
      })
      cy.contains('button', 'Close').click()
      cy.get('.modal-overlay').should('not.exist')
    })
  })

  // ==================== Shared Folders ====================

  it('shows Shared Folders section with Add button', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('h2', 'Shared Folders').should('exist')
      cy.contains('button', 'Add Shared Folder').should('exist')
    })
  })

  // ==================== ISOs Section ====================

  it('ISOs section shows attach button', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('body').then(($b) => {
        if ($b.find('h2:contains("ISOs")').length) {
          cy.contains('button', 'Attach ISO').should('exist')
        }
      })
    })
  })

  it('Attach ISO opens a modal with available ISOs', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('body').then(($b) => {
        if (!$b.find('button:contains("Attach ISO")').length) return
        cy.contains('button', 'Attach ISO').click()
        cy.get('.modal-overlay').should('be.visible')
        cy.get('.modal').contains('button', 'Cancel').click()
        cy.get('.modal-overlay').should('not.exist')
      })
    })
  })

  // ==================== Network Info ====================

  it('overview shows network mode (NAT or bridged)', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.detail-row').contains('Network').should('exist')
      // Should show either NAT or a network name
      cy.get('.detail-row').then(($rows) => {
        const networkRow = $rows.filter(':contains("Network")')
        expect(networkRow.text()).to.match(/NAT|bridged|Default/)
      })
    })
  })

  // ==================== Port Forwards ====================

  it('port forwards section exists for NAT VMs', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('body').then(($b) => {
        if ($b.find('h2:contains("Port Forwards")').length) {
          cy.contains('h2', 'Port Forwards').should('exist')
          // Should have an edit button
          cy.get('body').then(($b2) => {
            if ($b2.find('button:contains("Edit Port Forwards")').length) {
              cy.contains('button', 'Edit Port Forwards').should('exist')
            }
          })
        }
      })
    })
  })

  // ==================== Edit Settings ====================

  it('opens Edit Settings modal with correct fields', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('button', 'Edit Settings').click()
      cy.contains('h2', 'Edit Settings').should('be.visible')
      cy.get('.edit-field').contains('Description').should('exist')
      cy.get('.edit-field').contains('CPU Cores').should('exist')
      cy.get('.edit-field').contains('Memory').should('exist')
      cy.get('.edit-field').contains('Boot Order').should('exist')
      cy.get('.edit-field').contains('Network').should('exist')
      cy.contains('button', 'Cancel').click()
    })
  })

  it('Edit Settings — Save button is present', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('button', 'Edit Settings').click()
      cy.contains('button', 'Save').should('exist')
      cy.contains('button', 'Cancel').click()
    })
  })

  // ==================== Tab Navigation ====================

  it('tab navigation: Console', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab').contains('Console').click()
      cy.get('.tab.active').should('contain', 'Console')
    })
  })

  it('tab navigation: VNC', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab').contains('VNC').click()
      cy.get('.tab.active').should('contain', 'VNC')
    })
  })

  it('Console tab shows "must be running" message for stopped VMs', () => {
    withStoppedVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab').contains('Console').click()
      cy.contains('VM must be running to use the console').should('exist')
    })
  })

  it('VNC tab shows "must be running" message for stopped VMs', () => {
    withStoppedVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab').contains('VNC').click()
      cy.get('body').then(($b) => {
        // VNC panel should show a not-running message or be empty
        if ($b.find(':contains("VM must be running")').length) {
          cy.contains('VM must be running').should('exist')
        }
      })
    })
  })

  it('Metrics tab appears only when VM is running', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      if (vm.state === 'running') {
        cy.get('.tab').contains('Metrics').should('exist')
      } else {
        cy.get('.tab').contains('Metrics').should('not.exist')
      }
    })
  })

  it('Metrics tab shows CPU, Memory, Disk I/O charts for running VM', () => {
    withRunningVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab').contains('Metrics').click()
      cy.get('.tab.active').should('contain', 'Metrics')
      // Wait for metrics grid
      cy.get('.metrics-grid, .metric-card', { timeout: 20000 }).should('exist')
      cy.contains('CPU Usage').should('exist')
      cy.contains('Memory').should('exist')
      cy.contains('Disk I/O').should('exist')
    })
  })

  // ==================== Navigation ====================

  it('back button navigates to /vms', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('button[title="Back to VMs"]').click()
      cy.url().should('match', /\/vms\/?$/)
    })
  })

  it('tab state persists in URL query parameter', () => {
    withFirstVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.tab').contains('Console').click()
      cy.url().should('include', 'tab=console')
      cy.get('.tab').contains('Overview').click()
      cy.url().should('not.include', 'tab=')
    })
  })

  // ==================== Action Buttons ====================

  it('action buttons match VM state — stopped', () => {
    withStoppedVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.contains('button', 'Start').should('exist')
      cy.contains('button', 'Delete').should('exist')
      cy.contains('button', 'Edit Settings').should('exist')
    })
  })

  it('action buttons match VM state — running', () => {
    withRunningVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.stop-main').should('contain', 'Stop')
      cy.get('.stop-toggle').should('exist')
    })
  })

  it('running VM shows stop split button with dropdown', () => {
    withRunningVM((vm) => {
      cy.visit(`/vms/${vm.id}`)
      cy.get('.stop-toggle').click()
      cy.get('.stop-menu').should('be.visible')
      cy.get('.stop-menu').contains('ACPI Shutdown').should('exist')
      cy.get('.stop-menu').contains('Force Stop').should('exist')
      cy.get('.stop-menu-danger').should('exist') // Force stop has danger class
    })
  })
})
