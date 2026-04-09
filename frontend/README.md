# BarkVisor Frontend

The web UI for [BarkVisor](../README.md), built with Vue 3, TypeScript, and Vite.

## Prerequisites

- [Bun](https://bun.sh)

## Development

```bash
bun install
bun run dev
```

The Vite dev server starts on `http://localhost:5173` with hot reload. API calls are proxied to the backend at `http://localhost:7777`.

## Production Build

```bash
bun run build
```

Output goes to `../Sources/BarkVisor/Resources/frontend/dist/` and is served by the backend directly.

## E2E Tests

```bash
bun run cy:open     # Interactive Cypress
bun run test:e2e    # Headless Cypress
```

## Project Structure

```
src/
  api/            API client modules (axios)
  assets/         Static assets
  components/     Reusable UI components
  composables/    Vue composables
  router/         Vue Router configuration
  stores/         Pinia stores (auth, vms, images, metrics, etc.)
  utils/          Utility functions
  views/          Page-level view components
  App.vue         Root component
  main.ts         Application entry point
```

## Tech Stack

- **Vue 3** with `<script setup>` and Composition API
- **TypeScript**
- **Vite** for dev server and bundling
- **Pinia** for state management
- **Vue Router** for client-side routing
- **axios** for HTTP requests
- **Chart.js** / **vue-chartjs** for metrics charts
- **xterm.js** for serial console
- **noVNC** for VNC display
- **Cypress** for E2E testing
