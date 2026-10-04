import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { validateArchive } from '../packetloss/runtime/validate-archive.mjs';

/** Encode a minimal POSIX tar fixture without using the production parser. */
function tarEntry(path, type = '0', data = '') {
  const header = Buffer.alloc(512);
  header.write(path, 0, 100);
  header.write('0000644\0', 100, 8);
  header.write('0000000\0', 108, 8);
  header.write('0000000\0', 116, 8);
  header.write(`${Buffer.byteLength(data).toString(8).padStart(11, '0')}\0`, 124, 12);
  header.write('00000000000\0', 136, 12);
  header.fill(32, 148, 156);
  header.write(type, 156, 1);
  if (type === '1' || type === '2') header.write('/etc/passwd', 157, 100);
  header.write('ustar', 257, 5);
  header.write('00', 263, 2);
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  header.write(`${checksum.toString(8).padStart(6, '0')}\0 `, 148, 8);
  const content = Buffer.alloc(Math.ceil(Buffer.byteLength(data) / 512) * 512);
  content.write(data);
  return Buffer.concat([header, content]);
}

/** Validate an authored compressed archive in an isolated directory. */
async function archive(t, entries) {
  const directory = await mkdtemp(join(tmpdir(), 'packetloss-archive-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'archive.tar.gz');
  await writeFile(path, gzipSync(Buffer.concat([...entries, Buffer.alloc(1024)])));
  return path;
}

test('accepts regular release files and directories', async t => {
  await validateArchive(await archive(t, [tarEntry('./', '5'), tarEntry('./server.js', '0', 'export {};')]));
});

for (const [path, type] of [['../outside', '0'], ['/absolute', '0'], ['folder/../../outside', '0'], ['symlink', '2'], ['hardlink', '1'], ['device', '3'], ['fifo', '6']]) {
  test(`rejects unsafe archive entry ${path} (${type})`, async t => {
    await assert.rejects(validateArchive(await archive(t, [tarEntry(path, type)])), /Unsafe archive entry/);
  });
}

test('rejects a PAX path override that escapes the destination', async t => {
  const record = '19 path=../outside\n';
  await assert.rejects(validateArchive(await archive(t, [tarEntry('PaxHeader', 'x', record), tarEntry('safe', '0')])), /Unsafe archive entry/);
});

test('rejects corrupt archives', async t => {
  const path = await archive(t, [Buffer.from('not a tar archive')]);
  await assert.rejects(validateArchive(path));
});
