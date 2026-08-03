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
      // Content lives under src/content/docs/docs/ → URLs /docs/...
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Docs home', link: '/docs/' },
            { label: 'Quickstart', link: '/docs/getting-started/quickstart/' },
            { label: 'First launch', link: '/docs/getting-started/first-launch/' },
            { label: 'Installation (macOS)', link: '/docs/getting-started/installation/' },
            { label: 'Linux support', link: '/docs/linux/' },
          ],
        },
        {
          label: 'Platforms',
          items: [
            { label: 'Linux (multi-distro)', link: '/docs/linux/' },
            { label: 'Development', link: '/docs/getting-started/development/' },
            { label: 'Building releases', link: '/docs/getting-started/building-releases/' },
          ],
        },
        {
          label: 'Reference',
          items: [
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
