/** Exercise the independent maximum-uptime stop policy without contacting AWS. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { checkUptime, requestOptions } from '../packetloss/runtime/watchdog.mjs';

/** Create a fixed boot and record cloud calls for independent stop assertions. */
function scenario({ state = 'running', uptime = 14401, fenceError, describeError, owner = 'i-owned' } = {}) {
  const calls = [];
  const now = Date.UTC(2026, 0, 1);
  const env = { INSTANCE_ID: 'i-owned', MAX_UPTIME_SECONDS: '14400', CONTROL_TABLE: 'control', GAME_REGION: 'eu' };
  const ec2 = { async send(command) {
    calls.push(command);
    if (command.constructor.name === 'DescribeInstancesCommand') {
      if (describeError) throw describeError;
      return { Reservations: [{ Instances: [{ State: { Name: state }, LaunchTime: new Date(now - uptime * 1000) }] }] };
    }
    return {};
  } };
  const table = { async send(command) {
    calls.push(command);
    if (fenceError) throw fenceError;
    return { Item: { activeRegion: { S: 'eu' }, instanceId: { S: owner }, instanceRunId: { S: 'run-owned' } } };
  } };
  return { calls, run: () => checkUptime({ env, ec2, table, now, log() {} }) };
}

test('stops only the configured instance at the deadline and fences its boot', async () => {
  const scenario_ = scenario({ uptime: 14400 });
  assert.deepEqual(await scenario_.run(), { checked: 'i-owned' });
  const [describe, get, update, stop] = scenario_.calls;
  assert.deepEqual(describe.input.InstanceIds, ['i-owned']);
  assert.equal(get.input.ConsistentRead, true);
  assert.equal(update.input.ExpressionAttributeValues[':run'].S, 'run-owned');
  assert.deepEqual(stop.input.InstanceIds, ['i-owned']);
  assert.deepEqual(requestOptions, { maxAttempts: 1, requestHandler: { connectionTimeout: 2000, requestTimeout: 3000, throwOnRequestTimeout: true } });
});

test('central outage cannot disable the independent cap', async () => {
  const scenario_ = scenario({ fenceError: new Error('DynamoDB unavailable') });
  await scenario_.run();
  assert.equal(scenario_.calls.at(-1).constructor.name, 'StopInstancesCommand');
});

test('an unrelated lease is not fenced while the configured expired instance stops', async () => {
  const scenario_ = scenario({ owner: 'i-other' });
  await scenario_.run();
  assert.equal(scenario_.calls.some(command => command.constructor.name === 'UpdateItemCommand'), false);
  assert.equal(scenario_.calls.at(-1).constructor.name, 'StopInstancesCommand');
});

for (const options of [{ uptime: 14399 }, { state: 'stopped', uptime: 90000 }]) {
  test(`does not stop ${options.state ?? 'running'} instance at ${options.uptime} seconds`, async () => {
    const scenario_ = scenario(options);
    await scenario_.run();
    assert.equal(scenario_.calls.length, 1);
  });
}

test('EC2 failure is reported for retry', async () => {
  const scenario_ = scenario({ describeError: new Error('EC2 unavailable') });
  await assert.rejects(scenario_.run(), /EC2 unavailable/);
  assert.equal(scenario_.calls.length, 1);
});
