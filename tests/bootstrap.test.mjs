import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('first bundle download uses IMDSv2 and passes signing credentials only through stdin', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'packetloss-bootstrap-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const trace = join(directory, 'trace');
  const configFile = join(directory, 'config');
  const source = await readFile(new URL('../terraform/modules/game-server/bootstrap.sh.tftpl', import.meta.url), 'utf8');
  const start = source.indexOf('# curl\'s native SigV4');
  const end = source.indexOf('unset credentials metadata_token', start) + 'unset credentials metadata_token'.length;
  assert.ok(start >= 0 && end > start);
  const snippet = source.slice(start, end).replaceAll('${artifacts_bucket}', 'owned-bucket').replaceAll('${management_key}', 'management/owned.zip');
  await writeFile(join(directory, 'curl'), `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CLI_TRACE, JSON.stringify(args) + '\\n');
if (args.includes('--aws-sigv4')) fs.writeFileSync(process.env.CLI_CONFIG, fs.readFileSync(0));
else if (args.at(-1).endsWith('/api/token')) console.log('metadata-token');
else if (args.at(-1).endsWith('/security-credentials/')) console.log('instance-role');
else console.log(JSON.stringify({Code:'Success',AccessKeyId:'fake-access',SecretAccessKey:'fake-secret',Token:'fake-session'}));
`, { mode: 0o755 });
  const result = spawnSync('bash', ['-euo', 'pipefail', '-c', snippet], { encoding: 'utf8', env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, CLI_TRACE: trace, CLI_CONFIG: configFile } });
  assert.equal(result.status, 0, result.stderr);
  const calls = (await readFile(trace, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.ok(calls[0].includes('X-aws-ec2-metadata-token-ttl-seconds: 60'));
  assert.ok(calls[1].includes('X-aws-ec2-metadata-token: metadata-token'));
  assert.ok(calls.at(-1).includes('aws:amz:us-east-1:s3'));
  assert.ok(calls.at(-1).includes('https://owned-bucket.s3.us-east-1.amazonaws.com/management/owned.zip'));
  assert.equal(JSON.stringify(calls).includes('fake-secret'), false);
  assert.equal(JSON.stringify(calls).includes('fake-session'), false);
  const config = await readFile(configFile, 'utf8');
  assert.match(config, /user = "fake-access:fake-secret"/);
  assert.match(config, /header = "x-amz-security-token: fake-session"/);
});
