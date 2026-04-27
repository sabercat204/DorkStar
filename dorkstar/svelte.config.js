// Use adapter-node when running in Docker / Node.js production environments.
// Falls back to adapter-auto for other deployment targets (Vercel, Cloudflare, etc.)
// by checking the SVELTE_ADAPTER env var.
import adapterNode from '@sveltejs/adapter-node';
import adapterAuto from '@sveltejs/adapter-auto';

const adapter = process.env.SVELTE_ADAPTER === 'node' ? adapterNode : adapterAuto;

/** @type {import('@sveltejs/kit').Config} */
const config = {
	compilerOptions: {
		// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
		runes: ({ filename }) => (filename.split(/[/\\]/).includes('node_modules') ? undefined : true)
	},
	kit: {
		adapter: adapter()
	}
};

export default config;
