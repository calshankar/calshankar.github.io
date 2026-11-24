import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** @typedef {{ subdir: string, urlPath: string }} ArtifactMount */

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const contentRoot = path.join(repoRoot, 'src/content');

/**
 * Blog-adjacent artefacts live under `src/content/{skills,workflow,scripts,manifests}`.
 * Each mount is copied/served at `/<urlPath>/…` (not under `/public/`).
 *
 * @type {ArtifactMount[]}
 */
export const ARTIFACT_MOUNTS = [
	{ subdir: 'skills', urlPath: 'skills' },
	{ subdir: 'workflow', urlPath: 'workflow' },
	// `public/scripts/` is site runtime JS (e.g. mermaid-expand). Blog scripts use another prefix.
	{ subdir: 'scripts', urlPath: 'blog-scripts' },
	{ subdir: 'manifests', urlPath: 'manifests' },
];

const MIME = {
	'.md': 'text/markdown; charset=utf-8',
	'.mdx': 'text/markdown; charset=utf-8',
	'.yaml': 'text/yaml; charset=utf-8',
	'.yml': 'text/yaml; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.sh': 'text/plain; charset=utf-8',
	'.bash': 'text/plain; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.mjs': 'text/javascript; charset=utf-8',
	'.txt': 'text/plain; charset=utf-8',
};

/**
 * @param {string} rootDir
 */
function staticMiddleware(rootDir) {
	return (req, res, next) => {
		const rel = decodeURIComponent((req.url ?? '/').split('?')[0]);
		const filePath = path.normalize(path.join(rootDir, rel));
		const normalizedRoot = path.normalize(rootDir);
		if (!filePath.startsWith(normalizedRoot)) {
			res.statusCode = 403;
			res.end('Forbidden');
			return;
		}
		if (!fs.existsSync(filePath)) {
			next();
			return;
		}
		const stat = fs.statSync(filePath);
		if (stat.isDirectory()) {
			const index = path.join(filePath, 'index.html');
			if (fs.existsSync(index)) {
				res.setHeader('Content-Type', 'text/html; charset=utf-8');
				res.end(fs.readFileSync(index));
				return;
			}
			next();
			return;
		}
		const ext = path.extname(filePath).toLowerCase();
		res.setHeader('Content-Type', MIME[ext] ?? 'application/octet-stream');
		res.end(fs.readFileSync(filePath));
	};
}

/**
 * Publishes `src/content` artefact folders from `ARTIFACT_MOUNTS` at build time
 * and via Vite dev middleware.
 */
export default function publishContentArtifacts() {
	return {
		name: 'publish-content-artifacts',
		hooks: {
			'astro:config:setup': ({ updateConfig }) => {
				updateConfig({
					vite: {
						plugins: [
							{
								name: 'publish-content-artifacts-dev',
								configureServer(server) {
									for (const { subdir, urlPath } of ARTIFACT_MOUNTS) {
										const root = path.join(contentRoot, subdir);
										if (!fs.existsSync(root)) continue;
										server.middlewares.use(`/${urlPath}`, staticMiddleware(root));
									}
								},
							},
						],
					},
				});
			},
			'astro:build:done': ({ dir }) => {
				const out = fileURLToPath(dir);
				for (const { subdir, urlPath } of ARTIFACT_MOUNTS) {
					const src = path.join(contentRoot, subdir);
					if (!fs.existsSync(src)) continue;
					fs.cpSync(src, path.join(out, urlPath), { recursive: true });
				}
			},
		},
	};
}