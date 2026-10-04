import { isAbsolute } from 'node:path/posix';
import { t } from 'tar';

/** Reject traversal, absolute paths, links and device entries before extraction. */
export async function validateArchive(file) {
  const invalid = [];
  await t({ file, strict: true, onReadEntry: entry => {
    if (isAbsolute(entry.path) || entry.path.split('/').includes('..') || !['File', 'Directory'].includes(entry.type)) invalid.push(entry.path);
  } });
  if (invalid.length) throw new Error(`Unsafe archive entry: ${invalid[0]}`);
}

if (import.meta.main) await validateArchive(process.argv[2]);
