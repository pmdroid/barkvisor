// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

/**
 * Single site: marketing landing at `/` + Starlight docs at `/docs/*`.
 * Cloudflare Pages: build command `bun run build`, output directory `dist`.
 */
export default defineConfig({
  site: 'https://barkvisor.dev',
  outDir: 'dist',
  publicDir: 'public',
  integrations: [
    starlight({
      title: 'BarkVisor',
      description:
        'Open-source QEMU virtualization for macOS and Linux — docs and guides.',
      favicon: '/favicon.png',
      logo: {
        src: './public/hero.png',
        alt: 'BarkVisor',
        replacesTitle: false,
      },
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/pmdroid/barkvisor',
        },
      ],
      customCss: ['./src/styles/starlight.css'],
      // Inject PostHog on every docs page (landing uses the same component in index.astro).
      components: {
        Head: './src/components/StarlightHead.astro',
      },
      // Content lives under src/content/docs/docs/ → URLs /docs/...
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Docs home', link: '/docs/' },
            { label: 'Quickstart', link: '/docs/getting-started/quickstart/' },
            { label: 'First launch', link: '/docs/getting-started/first-launch/' },
            { label: 'Home and pairing', link: '/docs/guides/home-and-pairing/' },
            { label: 'Create a Workload', link: '/docs/guides/create-workload/' },
            { label: 'Changelog', link: '/docs/changelog/' },
            { label: 'Roadmap', link: '/docs/roadmap/' },
            { label: 'Installation (macOS)', link: '/docs/getting-started/installation/' },
            { label: 'Installation (Linux)', link: '/docs/linux/' },
          ],
        },
        {
          label: 'Using BarkVisor',
          items: [
            { label: 'Using the web UI', link: '/docs/using/' },
            { label: 'Dashboard', link: '/docs/using/dashboard/' },
            { label: 'Devices', link: '/docs/using/devices/' },
            { label: 'Virtual Machines', link: '/docs/using/vms/' },
            { label: 'Workload details', link: '/docs/using/vm-details/' },
            { label: 'Ollama', link: '/docs/using/ollama/' },
            { label: 'Chat', link: '/docs/using/chat/' },
            { label: 'Images', link: '/docs/using/images/' },
            { label: 'Disks', link: '/docs/using/disks/' },
            { label: 'Networks', link: '/docs/using/networks/' },
            { label: 'Repositories', link: '/docs/using/repositories/' },
            { label: 'Logs', link: '/docs/using/logs/' },
            {
              label: 'Settings',
              items: [
                { label: 'Settings overview', link: '/docs/using/settings/' },
                { label: 'Home', link: '/docs/using/settings/home/' },
                { label: 'Pairing', link: '/docs/using/settings/pairing/' },
                { label: 'Library', link: '/docs/using/settings/library/' },
                { label: 'Disks', link: '/docs/using/settings/disks/' },
                { label: 'API Keys', link: '/docs/using/settings/api-keys/' },
                { label: 'SSH Keys', link: '/docs/using/settings/ssh-keys/' },
                { label: 'Audit Log', link: '/docs/using/settings/audit-log/' },
              ],
            },
          ],
        },
        {
          label: 'Build',
          items: [
            { label: 'Development', link: '/docs/getting-started/development/' },
            { label: 'Guest-boot CI', link: '/docs/getting-started/ci-kvm-runner/' },
            { label: 'Building releases', link: '/docs/getting-started/building-releases/' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Terminology', link: '/docs/concepts/terminology/' },
            { label: 'Troubleshooting', link: '/docs/getting-started/troubleshooting/' },
          ],
        },
      ],
      head: [
        {
          tag: 'link',
          attrs: {
            rel: 'preconnect',
            href: 'https://fonts.googleapis.com',
          },
        },
        {
          tag: 'link',
          attrs: {
            rel: 'preconnect',
            href: 'https://fonts.gstatic.com',
            crossorigin: 'anonymous',
          },
        },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href: 'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap',
          },
        },
      ],
    }),
  ],
});
