// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightThemeNext from 'starlight-theme-next';

export default defineConfig({
	site: 'https://martineastwood.github.io',
	base: '/nimgent',
	integrations: [
		starlight({
			title: 'nimgent',
			description: 'A lightweight Nim client for provider-native LLM applications.',
			customCss: ['./src/styles/sidebar.css'],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/martineastwood/nimgent' }],
			sidebar: [
				{ label: 'Introduction', slug: 'index' },
				{ label: 'Quickstart', slug: 'guides/quickstart' },
				{
					label: 'Providers',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'guides/providers' },
						{ label: 'Settings', slug: 'guides/providers/settings' },
						{ label: 'OpenAI', slug: 'guides/providers/openai' },
						{ label: 'Anthropic', slug: 'guides/providers/anthropic' },
						{ label: 'Google Gemini', slug: 'guides/providers/google' },
						{ label: 'OpenRouter', slug: 'guides/providers/openrouter' },
						{ label: 'Hyper', slug: 'guides/providers/hyper' },
						{ label: 'Mistral', slug: 'guides/providers/mistral' },
						{ label: 'OpenCode', slug: 'guides/providers/opencode' },
						{ label: 'Custom provider', slug: 'guides/providers/custom-provider' },
					],
				},
				{ label: 'Streaming', slug: 'guides/streaming' },
				{ label: 'Tracing', slug: 'guides/tracing' },
				{ label: 'Tools and agents', slug: 'guides/tools-and-agents' },
				{ label: 'Structured output', slug: 'guides/structured-output' },
				{ label: 'Sessions', slug: 'guides/sessions' },
				{ label: 'Files and images', slug: 'guides/files-and-images' },
				{ label: 'MCP tools', slug: 'guides/mcp' },
				{ label: 'Embeddings and retrieval', slug: 'guides/embeddings-and-retrieval' },
				{ label: 'Middleware and routing', slug: 'guides/middleware-and-routing' },
				{ label: 'Errors and retries', slug: 'guides/errors-and-retries' },
				{ label: 'Testing', slug: 'guides/testing' },
				{
					label: 'API reference',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'reference/core-api' },
						{ autogenerate: { directory: 'reference/api' } },
					],
				},
                {
					label: 'Examples',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'examples' },
						{ label: 'Generate text', slug: 'examples/generate-text' },
						{ label: 'Stream text', slug: 'examples/stream-text' },
						{ label: 'Async generation', slug: 'examples/async-generation' },
						{ label: 'Tool call', slug: 'examples/tool-call' },
						{ label: 'Agent', slug: 'examples/agent' },
						{ label: 'Agent events', slug: 'examples/agent-events' },
						{ label: 'Lifecycle callbacks', slug: 'examples/lifecycle-callbacks' },
						{ label: 'Structured output', slug: 'examples/structured-output' },
						{ label: 'Stream object', slug: 'examples/stream-object' },
						{ label: 'Session', slug: 'examples/session' },
						{ label: 'Embeddings', slug: 'examples/embeddings' },
						{ label: 'Provider options', slug: 'examples/provider-options' },
						{ label: 'Wrap provider', slug: 'examples/wrap-provider' },
						{ label: 'Chat with PDF', slug: 'examples/chat-with-pdf' },
						{ label: 'MCP client', slug: 'examples/mcp-client' },
						{ label: 'Anthropic smoke test', slug: 'examples/anthropic-smoke' },
						{ label: 'Google smoke test', slug: 'examples/google-smoke' },
					],
				},
			],
			plugins: [
				starlightThemeNext(),
			],
		}),
	],
});
