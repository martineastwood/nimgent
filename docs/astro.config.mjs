// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeBlack from 'starlight-theme-black';

export default defineConfig({
	site: 'https://nimgent.niminal.dev',
	integrations: [
		starlight({
			title: 'nimgent',
			description: 'A lightweight Nim client for provider-native LLM applications.',
			customCss: ['./src/styles/sidebar.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimgent' }],
			sidebar: [
				{ label: 'Introduction', slug: 'index' },
				{ label: 'Quickstart', slug: 'guides/quickstart' },
				{ label: 'Providers', slug: 'guides/providers' },
				{ label: 'Streaming', slug: 'guides/streaming' },
				{ label: 'Tools and agents', slug: 'guides/tools-and-agents' },
				{ label: 'Structured output', slug: 'guides/structured-output' },
				{ label: 'Sessions', slug: 'guides/sessions' },
				{ label: 'Core API', slug: 'reference/core-api' },
				{ label: 'Examples', slug: 'reference/examples' },
			],
			plugins: [
				starlightThemeBlack({
					navLinks: [{ label: 'Niminal', link: 'https://niminal.dev' }],
					docs: { showMarkdownActions: false },
				}),
			],
		}),
	],
});
