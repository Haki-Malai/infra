import { build } from 'esbuild';
import { rm } from 'node:fs/promises';

await rm('dist', { recursive: true, force: true });
await build({
  entryPoints: ['runtime/watchdog.mjs', 'runtime/idle.mjs', 'runtime/certificate.mjs', 'runtime/validate-archive.mjs', 'runtime/cloud.mjs'],
  outdir: 'dist', outExtension: { '.js': '.mjs' }, bundle: true,
  platform: 'node', target: 'node22', format: 'esm', minify: true,
  banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
});
