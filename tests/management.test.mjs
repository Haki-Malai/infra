/** Verify management command routing using local stubs, with no AWS/network calls. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../scripts/game-server', import.meta.url));

/** Replace only the network commands with traceable local executables. */
async function setup(t) {
  const directory = await mkdtemp(join(tmpdir(), 'packetloss-management-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const trace = join(directory, 'trace.jsonl');
  const config = join(directory, 'config.json');
  await writeFile(config, JSON.stringify({ control_lambda: 'packetloss-control', regions: { eu: { awsRegion: 'eu-central-1' }, na: { awsRegion: 'us-east-1' } } }));
  for (const tool of ['curl', 'node']) {
    await writeFile(join(directory, tool), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
if ('${tool}' === 'node') args.shift();
fs.appendFileSync(process.env.CLI_TRACE, JSON.stringify(['${tool}', args]) + '\\n');
if ('${tool}' === 'curl') {
  if (args.at(-1).endsWith('/start')) console.log(JSON.stringify({phase:'starting'}));
  else { const phase = fs.existsSync(process.env.CLI_MARKER) ? 'stopped' : 'ready'; console.log(JSON.stringify({phase,activeRegion:'eu',regions:{eu:{phase}}})); }
} else if (args[0] === 'lambda-invoke') {
  fs.writeFileSync(args.at(-1), JSON.stringify({statusCode:202,phase:'stopping'}));
  fs.writeFileSync(process.env.CLI_MARKER, ''); console.log('{}');
} else if (args[0] === 'logs-tail') console.log('test log');
else throw new Error('Unexpected remote API');
`, { mode: 0o755 });
  }
  const env = { ...process.env, PATH: `${directory}:${process.env.PATH}`, GAME_SERVER_CONFIG: config, GAME_SERVER_TOKEN: 'test-token', CLI_TRACE: trace, CLI_MARKER: join(directory, 'stopped') };
  return { trace, command: (...args) => spawnSync('bash', [script, ...args], { env, encoding: 'utf8', timeout: 5000 }), calls: async () => (await readFile(trace, 'utf8')).trim().split('\n').map(line => JSON.parse(line)) };
}

test('force stop infers region and only invokes the control Lambda', async t => {
  const context = await setup(t);
  const result = context.command('stop', '--force');
  assert.equal(result.status, 0, result.stderr);
  const calls = (await context.calls()).filter(([tool]) => tool === 'node');
  assert.equal(calls.length, 1);
  const args = calls[0][1];
  assert.deepEqual(JSON.parse(args[2]), { source: 'packetloss-operator', operation: 'stop', region: 'eu', force: true });
});

test('start accepts the documented region flag without exposing the token in argv', async t => {
  const context = await setup(t);
  const result = context.command('start', '--region', 'na');
  assert.equal(result.status, 0, result.stderr);
  const args = (await context.calls())[0][1];
  assert.deepEqual(JSON.parse(args[args.indexOf('--data') + 1]), { region: 'na' });
  assert.equal(args.join(' ').includes('test-token'), false);
});

test('logs infer the active region', async t => {
  const context = await setup(t);
  const result = context.command('logs');
  assert.equal(result.status, 0, result.stderr);
  const args = (await context.calls()).find(([tool]) => tool === 'node')[1];
  assert.ok(args.includes('/packetloss/game/eu-central-1'));
});

test('invalid region does not contact a remote service', async t => {
  const context = await setup(t);
  assert.equal(context.command('start', '--region', 'other').status, 2);
  await assert.rejects(access(context.trace), { code: 'ENOENT' });
});
