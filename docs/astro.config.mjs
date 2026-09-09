// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeBlack from 'starlight-theme-black';

export default defineConfig({
	integrations: [
		starlight({
			title: 'nimgent',
			description: 'A lightweight Nim client for provider-native LLM applications.',
			customCss: ['./src/styles/sidebar.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martinrusev/nimgent' }],
			sidebar: [
				{
					label: 'Start here',
					items: [
						{ label: 'Introduction', slug: 'index' },
						{ label: 'Quickstart', slug: 'guides/quickstart' },
					],
				},
				{
					label: 'Guides',
					items: [
						{ label: 'Providers', slug: 'guides/providers' },
						{ label: 'Streaming', slug: 'guides/streaming' },
						{ label: 'Tools and agents', slug: 'guides/tools-and-agents' },
						{ label: 'Structured output', slug: 'guides/structured-output' },
						{ label: 'Sessions', slug: 'guides/sessions' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'Core API', slug: 'reference/core-api' },
						{ label: 'Examples', slug: 'reference/examples' },
					],
				},
			],
			plugins: [
				starlightThemeBlack({
					navLinks: [
						{ label: 'GitHub', link: 'https://github.com/martinrusev/nimgent' },
					],
					docs: { showMarkdownActions: false },
				}),
			],
		}),
	],
});
