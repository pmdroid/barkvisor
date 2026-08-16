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
    description: 'Install BarkVisor on macOS with the .pkg or standalone archive.',
  },
  'getting-started-linux.md': {
    out: 'linux.md',
    title: 'Installation (Linux)',
    description:
      'Install BarkVisor on Linux with .deb / .rpm / tarball packages and systemd.',
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
    description: 'macOS release packages and Linux .deb / .rpm / tarball builds.',
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

console.log('done');
