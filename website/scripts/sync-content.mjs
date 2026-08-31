#!/usr/bin/env node
/**
 * Sync repo docs/*.md into Starlight content under /docs/*.
 * Source of truth: ../../docs (repo root).
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '../..');
const docsDir = path.join(root, 'docs');
const outDir = path.resolve(__dirname, '../src/content/docs/docs');

/** @type {Record<string, { out: string, title: string, description: string }>} */
const map = {
  'getting-started-installation.md': {
    out: 'getting-started/installation.md',
    title: 'Installation (macOS)',
    description: 'Install BarkVisor on Apple Silicon with the .pkg. Updates from Settings.',
  },
  'getting-started-linux.md': {
    out: 'linux.md',
    title: 'Installation (Linux)',
    description:
      'Install BarkVisor on Ubuntu or Debian with the .deb. Root systemd unit.',
  },
  'getting-started-first-launch.md': {
    out: 'getting-started/first-launch.md',
    title: 'First launch and setup',
    description: 'Web-based setup wizard, admin account, and platform-specific bridge helpers.',
  },
  'getting-started-quickstart.md': {
    out: 'getting-started/quickstart.md',
    title: 'Quickstart',
    description: 'Download an image and create your first VM on macOS or Linux.',
  },
  'getting-started-development.md': {
    out: 'getting-started/development.md',
    title: 'Development',
    description: 'Build BarkVisor from source for local development.',
  },
  'ci-kvm-runner.md': {
    out: 'getting-started/ci-kvm-runner.md',
    title: 'Guest-boot CI',
    description:
      'Optional GitHub Actions guest-boot lanes and the self-hosted KVM runner.',
  },
  'getting-started-building-releases.md': {
    out: 'getting-started/building-releases.md',
    title: 'Building releases',
    description: 'macOS .pkg and Linux package builds. Appliance channel is .deb + .pkg.',
  },
  'getting-started-troubleshooting.md': {
    out: 'getting-started/troubleshooting.md',
    title: 'Troubleshooting',
    description: 'Common issues on macOS and Linux.',
  },
  'product-terminology.md': {
    out: 'concepts/terminology.md',
    title: 'Product terminology',
    description: 'Home and Device — words for the tenancy and the machine running BarkVisor.',
  },
  'home-and-pairing.md': {
    out: 'guides/home-and-pairing.md',
    title: 'Home and pairing',
    description: 'Add a Device to a Home, join from setup or the CLI, and what pairing does not do.',
  },
  'ollama.md': {
    out: 'guides/ollama.md',
    title: 'Ollama',
    description: 'Install Ollama, pull models, Start on the Device that has the weights, search the library.',
  },
  'create-workload.md': {
    out: 'guides/create-workload.md',
    title: 'Create a Workload',
    description: 'Create a VM on this Device or another paired Device from the Home dashboard.',
  },
  'using-overview.md': {
    out: 'using/index.md',
    title: 'Using the web UI',
    description:
      'Run BarkVisor, sign in, and a map of every menu point in the console.',
  },
  'using-dashboard.md': {
    out: 'using/dashboard.md',
    title: 'Dashboard',
    description: 'The triage inbox for your Home — incidents, feed columns, and vitals.',
  },
  'using-devices.md': {
    out: 'using/devices.md',
    title: 'Devices',
    description: 'Every machine in your Home: health cards, facts, and its Workloads.',
  },
  'using-vms.md': {
    out: 'using/vms.md',
    title: 'Virtual Machines',
    description: 'All Workloads in the Home with health filters and quick actions.',
  },
  'using-vm-details.md': {
    out: 'using/vm-details.md',
    title: 'Workload details',
    description: 'Actions and tabs for one VM: overview, console, VNC, metrics, logs.',
  },
  'using-ollama.md': {
    out: 'using/ollama.md',
    title: 'Ollama',
    description: 'Model runtime status per Device, pulling models, and API access.',
  },
  'using-images.md': {
    out: 'using/images.md',
    title: 'Images',
    description: 'The OS image library on this Device — upload, download, free space.',
  },
  'using-disks.md': {
    out: 'using/disks.md',
    title: 'Disks',
    description: 'Create, resize, attach, and delete virtual disks across the Home.',
  },
  'using-networks.md': {
    out: 'using/networks.md',
    title: 'Networks',
    description: 'Host interfaces, VM networks, and multi-address Device addressing.',
  },
  'settings-repositories.md': {
    out: 'using/settings/repositories.md',
    title: 'Settings: Repositories',
    description: 'Catalog URLs and per-Device sync for templates and images.',
  },
  'using-logs.md': {
    out: 'using/logs.md',
    title: 'Logs',
    description: 'Searchable log stream across Devices with live tail and diagnostics.',
  },
  'using-settings.md': {
    out: 'using/settings/index.md',
    title: 'Settings',
    description: 'The Settings tabs, including Updates on a root appliance.',
  },
  'settings-updates.md': {
    out: 'using/settings/updates.md',
    title: 'Settings: Updates',
    description: 'Apply a checksummed .deb or .pkg on a root Device.',
  },
  'settings-home.md': {
    out: 'using/settings/home.md',
    title: 'Settings: Home',
    description: 'Device facts and Device URL.',
  },
  'settings-pairing.md': {
    out: 'using/settings/pairing.md',
    title: 'Settings: Pairing',
    description: 'Pairing QR to add Devices, phone sign-in QR, and re-pairing.',
  },
  'settings-library.md': {
    out: 'using/settings/library.md',
    title: 'Settings: Library',
    description: 'Library path, capacity, and reset.',
  },
  'settings-disks.md': {
    out: 'using/settings/disks.md',
    title: 'Settings: Disks',
    description: 'Default VM disk directory for new disks on this Device.',
  },
  'settings-api-keys.md': {
    out: 'using/settings/api-keys.md',
    title: 'Settings: API Keys',
    description: 'Create, show-once, and revoke inference or full API keys.',
  },
  'settings-ssh-keys.md': {
    out: 'using/settings/ssh-keys.md',
    title: 'Settings: SSH Keys',
    description: 'Public keys injected into guests, defaults, and deletion.',
  },
  'settings-passkeys.md': {
    out: 'using/settings/passkeys.md',
    title: 'Settings: Passkeys',
    description: 'WebAuthn passkeys for passwordless web sign-in.',
  },
  'settings-audit-log.md': {
    out: 'using/settings/audit-log.md',
    title: 'Settings: Audit Log',
    description: 'Who changed what, when, and how they authenticated.',
  },
  'changelog.md': {
    out: 'changelog.md',
    title: 'Changelog',
    description: 'What shipped for Home pairing, Library, and Create VM.',
  },
  'roadmap.md': {
    out: 'roadmap.md',
    title: 'Roadmap',
    description: 'Product ideas ahead: Home HA, quorum, Ceph, live migration, apps, and backups.',
  },
};

function stripFirstH1(body) {
  return body.replace(/^#\s+[^\n]+\n+/, '');
}

function fixLinks(body) {
  return body
    .replace(/\]\(getting-started-linux\.md(#[^)]*)?\)/g, '](/docs/linux/$1)')
    .replace(/\]\(getting-started-installation\.md(#[^)]*)?\)/g, '](/docs/getting-started/installation/$1)')
    .replace(/\]\(getting-started-first-launch\.md(#[^)]*)?\)/g, '](/docs/getting-started/first-launch/$1)')
    .replace(/\]\(getting-started-quickstart\.md(#[^)]*)?\)/g, '](/docs/getting-started/quickstart/$1)')
    .replace(/\]\(getting-started-development\.md(#[^)]*)?\)/g, '](/docs/getting-started/development/$1)')
    .replace(/\]\(ci-kvm-runner\.md(#[^)]*)?\)/g, '](/docs/getting-started/ci-kvm-runner/$1)')
    .replace(/\]\(getting-started-building-releases\.md(#[^)]*)?\)/g, '](/docs/getting-started/building-releases/$1)')
    .replace(/\]\(getting-started-troubleshooting\.md(#[^)]*)?\)/g, '](/docs/getting-started/troubleshooting/$1)')
    .replace(/\]\(product-terminology\.md(#[^)]*)?\)/g, '](/docs/concepts/terminology/$1)')
    .replace(/\]\(home-and-pairing\.md(#[^)]*)?\)/g, '](/docs/guides/home-and-pairing/$1)')
    .replace(/\]\(ollama\.md(#[^)]*)?\)/g, '](/docs/guides/ollama/$1)')
    .replace(/\]\(create-workload\.md(#[^)]*)?\)/g, '](/docs/guides/create-workload/$1)')
    .replace(/\]\(img\/([^)]+)\)/g, '](/docs-img/$1)')
    .replace(/\]\(using-overview\.md(#[^)]*)?\)/g, '](/docs/using/$1)')
    .replace(/\]\(using-dashboard\.md(#[^)]*)?\)/g, '](/docs/using/dashboard/$1)')
    .replace(/\]\(using-devices\.md(#[^)]*)?\)/g, '](/docs/using/devices/$1)')
    .replace(/\]\(using-vms\.md(#[^)]*)?\)/g, '](/docs/using/vms/$1)')
    .replace(/\]\(using-vm-details\.md(#[^)]*)?\)/g, '](/docs/using/vm-details/$1)')
    .replace(/\]\(using-ollama\.md(#[^)]*)?\)/g, '](/docs/using/ollama/$1)')
    .replace(/\]\(using-images\.md(#[^)]*)?\)/g, '](/docs/using/images/$1)')
    .replace(/\]\(using-disks\.md(#[^)]*)?\)/g, '](/docs/using/disks/$1)')
    .replace(/\]\(using-networks\.md(#[^)]*)?\)/g, '](/docs/using/networks/$1)')
    .replace(/\]\(using-repositories\.md(#[^)]*)?\)/g, '](/docs/using/settings/repositories/$1)')
    .replace(/\]\(settings-repositories\.md(#[^)]*)?\)/g, '](/docs/using/settings/repositories/$1)')
    .replace(/\]\(using-logs\.md(#[^)]*)?\)/g, '](/docs/using/logs/$1)')
    .replace(/\]\(using-settings\.md(#[^)]*)?\)/g, '](/docs/using/settings/$1)')
    .replace(/\]\(settings-home\.md(#[^)]*)?\)/g, '](/docs/using/settings/home/$1)')
    .replace(/\]\(settings-pairing\.md(#[^)]*)?\)/g, '](/docs/using/settings/pairing/$1)')
    .replace(/\]\(settings-library\.md(#[^)]*)?\)/g, '](/docs/using/settings/library/$1)')
    .replace(/\]\(settings-disks\.md(#[^)]*)?\)/g, '](/docs/using/settings/disks/$1)')
    .replace(/\]\(settings-updates\.md(#[^)]*)?\)/g, '](/docs/using/settings/updates/$1)')
    .replace(/\]\(settings-api-keys\.md(#[^)]*)?\)/g, '](/docs/using/settings/api-keys/$1)')
    .replace(/\]\(settings-ssh-keys\.md(#[^)]*)?\)/g, '](/docs/using/settings/ssh-keys/$1)')
    .replace(/\]\(settings-passkeys\.md(#[^)]*)?\)/g, '](/docs/using/settings/passkeys/$1)')
    .replace(/\]\(settings-audit-log\.md(#[^)]*)?\)/g, '](/docs/using/settings/audit-log/$1)')
    .replace(/\]\(changelog\.md(#[^)]*)?\)/g, '](/docs/changelog/$1)')
    .replace(/\]\(roadmap\.md(#[^)]*)?\)/g, '](/docs/roadmap/$1)')
    .replace(/\]\(host-process-boundary\.md(#[^)]*)?\)/g, '](https://github.com/pmdroid/barkvisor/blob/main/docs/host-process-boundary.md$1)')
    .replace(/\]\(\.\.\/\.github\/([^)]+)\)/g, '](https://github.com/pmdroid/barkvisor/blob/main/.github/$1)')
    .replace(/\]\(\.\.\/packaging\/linux\/README\.md\)/g, '](https://github.com/pmdroid/barkvisor/tree/main/packaging/linux)')
    .replace(/\/docs\/([^)#\s]+)\/(#[^)]*)\)/g, '/docs/$1$2)');
}

// Remove previously generated pages (keep hand-written index.mdx)
for (const rel of Object.values(map).map((m) => m.out)) {
  const p = path.join(outDir, rel);
  if (fs.existsSync(p)) fs.unlinkSync(p);
}

fs.mkdirSync(outDir, { recursive: true });

for (const [srcName, meta] of Object.entries(map)) {
  const srcPath = path.join(docsDir, srcName);
  if (!fs.existsSync(srcPath)) {
    console.warn(`skip missing ${srcName}`);
    continue;
  }
  let body = fs.readFileSync(srcPath, 'utf8');
  body = stripFirstH1(body);
  body = fixLinks(body);

  const frontmatter = [
    '---',
    `title: ${JSON.stringify(meta.title)}`,
    `description: ${JSON.stringify(meta.description)}`,
    '---',
    '',
  ].join('\n');

  const outPath = path.join(outDir, meta.out);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, frontmatter + body);
  console.log(`synced ${srcName} → src/content/docs/docs/${meta.out}`);
}

console.log('done')

const imgDir = path.join(docsDir, 'img');
const imgOut = path.resolve(__dirname, '../public/docs-img');
if (fs.existsSync(imgDir)) {
  fs.rmSync(imgOut, { recursive: true, force: true });
  fs.mkdirSync(imgOut, { recursive: true });
  for (const f of fs.readdirSync(imgDir)) {
    fs.copyFileSync(path.join(imgDir, f), path.join(imgOut, f));
  }
  console.log(`synced docs/img → public/docs-img (${fs.readdirSync(imgDir).length} files)`);
};
