import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { runCloud, publishSite } from '../packetloss/runtime/cloud.mjs';

/** Isolate files used by the operational CLI without making network requests. */
async function directory(t) {
  const path = await mkdtemp(join(tmpdir(), 'packetloss-cloud-'));
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}

test('unknown operations fail before credentials or cloud clients are accessed', async () => {
  await assert.rejects(runCloud(['remove-everything'], { getClient() { assert.fail('unexpected cloud client'); } }), /Unsupported operation/);
});

test('Lambda deployment waits for each update and selects the matching Node handler', async t => {
  const file = join(await directory(t), 'api.zip');
  await writeFile(file, 'zip fixture');
  const calls = [];
  await runCloud(['lambda-deploy', 'packetloss-dev-api', file, 'account.handler'], {
    getClient: () => ({ async send(command) { calls.push(command); } }),
    waitLambda: async () => { calls.push('wait'); },
  });
  assert.equal(calls[0].constructor.name, 'UpdateFunctionCodeCommand');
  assert.equal(calls[0].input.FunctionName, 'packetloss-dev-api');
  assert.deepEqual(calls[2].input, { FunctionName: 'packetloss-dev-api', Runtime: 'nodejs22.x', Handler: 'account.handler' });
  assert.equal(calls[1], 'wait');
  assert.equal(calls[3], 'wait');
});

test('the real Lambda waiter uses only the configuration read allowed by deployment IAM', async t => {
  const file = join(await directory(t), 'api.zip');
  await writeFile(file, 'zip fixture');
  const calls = [];
  await runCloud(['lambda-deploy', 'packetloss-dev-api', file, 'account.handler'], {
    getClient: () => ({ async send(command) {
      const name = command.constructor.name;
      calls.push(name);
      assert.notEqual(name, 'GetFunctionCommand', 'deployment IAM does not grant lambda:GetFunction');
      return { LastUpdateStatus: 'Successful' };
    } }),
  });
  assert.deepEqual(calls, [
    'UpdateFunctionCodeCommand', 'GetFunctionConfigurationCommand',
    'UpdateFunctionConfigurationCommand', 'GetFunctionConfigurationCommand',
  ]);
});

test('site publication sends assets first, preserves old files, and invalidates after entrypoints', async t => {
  const path = await directory(t);
  await mkdir(join(path, 'assets'));
  await writeFile(join(path, 'assets', 'app.js'), 'app');
  await writeFile(join(path, 'index.html'), '<html>');
  await writeFile(join(path, 'deployment.json'), '{}');
  const calls = [];
  const s3 = { async send(command) { calls.push(command); } };
  const cloudfront = { async send(command) { calls.push(command); return { Invalidation: { Id: 'owned' } }; } };
  await publishSite(s3, cloudfront, 'site', path, 'distribution', async (_options, input) => {
    assert.deepEqual(input, { DistributionId: 'distribution', Id: 'owned' });
    calls.push('wait');
  });
  assert.deepEqual(calls.slice(0, 3).map(call => call.input.Key), ['assets/app.js', 'index.html', 'deployment.json']);
  assert.equal(calls[0].input.CacheControl, 'public,max-age=300');
  assert.equal(calls[1].input.CacheControl, 'no-cache,no-store,must-revalidate');
  assert.equal(calls[2].input.ContentType, 'application/json');
  assert.equal(calls[3].constructor.name, 'CreateInvalidationCommand');
  assert.equal(calls[4], 'wait');
});

test('S3 download streams the selected immutable object into the requested file', async t => {
  const file = join(await directory(t), 'artifact');
  await runCloud(['s3-get', 'artifacts', 'releases/owned/server.tar.gz', file], {
    getClient: () => ({ async send(command) {
      assert.deepEqual(command.input, { Bucket: 'artifacts', Key: 'releases/owned/server.tar.gz' });
      return { Body: Readable.from(['artifact bytes']) };
    } }),
  });
  assert.equal(await readFile(file, 'utf8'), 'artifact bytes');
});

test('operator invocation preserves function errors and response body for the stop guard', async t => {
  const file = join(await directory(t), 'response');
  const printed = [];
  await runCloud(['lambda-invoke', 'control', '{"operation":"stop"}', file], {
    getClient: () => ({ async send(command) {
      assert.equal(command.input.Payload.toString(), '{"operation":"stop"}');
      return { FunctionError: 'Unhandled', Payload: Buffer.from('{"error":"denied"}') };
    } }), print: value => printed.push(value),
  });
  assert.equal(JSON.parse(printed[0]).FunctionError, 'Unhandled');
  assert.equal(await readFile(file, 'utf8'), '{"error":"denied"}');
});

test('SSM commands keep the target, fixed document and existing execution bound', async () => {
  await runCloud(['ssm-command', 'eu-central-1', 'i-owned', 'reviewed command'], {
    getClient: (service, region) => {
      assert.equal(service, 'ssm'); assert.equal(region, 'eu-central-1');
      return { async send(command) {
        assert.deepEqual(command.input, { InstanceIds: ['i-owned'], DocumentName: 'AWS-RunShellScript', Parameters: { commands: ['reviewed command'], executionTimeout: ['900'] } });
        return { Command: { CommandId: 'command-owned' } };
      } };
    }, print: value => assert.equal(value, 'command-owned'),
  });
});

test('log inspection follows pagination and preserves the one-hour bound', async () => {
  const printed = [];
  let page = 0;
  await runCloud(['logs-tail', 'eu-central-1', '/packetloss/game/eu-central-1'], {
    now: 7200000, print: value => printed.push(value), getClient: () => ({ async send(command) {
      assert.equal(command.input.startTime, 3600000);
      return ++page === 1 ? { events: [{ timestamp: 4000000, message: 'first\n' }], nextToken: 'page2' } : { events: [{ timestamp: 5000000, message: 'second' }] };
    } }),
  });
  assert.equal(page, 2);
  assert.equal(printed.length, 2);
});
