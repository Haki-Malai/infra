import test from 'node:test';
import assert from 'node:assert/strict';
import { stopIfIdle } from '../packetloss/runtime/idle.mjs';

const idle = { activeMatches: 0, connectedPlayers: 0, pendingResults: 0, idleMs: 1_200_000 };

/** Run one idle transition with authored status responses and local cloud stubs. */
async function run(statuses, { fenceError, stopError } = {}) {
  const calls = [];
  const options = {
    env: { GAME_REGION: 'eu', GAME_INSTANCE_ID: 'i-owned', GAME_INSTANCE_RUN_ID: 'run-owned', GAME_CONTROL_TABLE: 'control' },
    request: async (path, method) => { calls.push([path, method]); return path === 'status' ? statuses.shift() : {}; },
    table: { async send(command) { calls.push(command); if (fenceError) throw fenceError; } },
    ec2: { async send(command) { calls.push(command); if (stopError) throw stopError; } },
  };
  let error;
  try { await stopIfIdle(options); } catch (caught) { error = caught; }
  return { calls, error };
}

test('idle shutdown drains, rechecks, fences its exact boot, then stops only itself', async () => {
  const { calls, error } = await run([{ ...idle }, { ...idle }]);
  assert.equal(error, undefined);
  assert.deepEqual(calls.slice(0, 3), [['status', undefined], ['drain', 'POST'], ['status', undefined]]);
  assert.equal(calls[3].input.ExpressionAttributeValues[':run'].S, 'run-owned');
  assert.deepEqual(calls[4].input.InstanceIds, ['i-owned']);
});

for (const status of [{ ...idle, activeMatches: 1 }, { ...idle, connectedPlayers: 1 }, { ...idle, pendingResults: 1 }, { ...idle, idleMs: 1199999 }]) {
  test(`active work prevents shutdown: ${JSON.stringify(status)}`, async () => {
    const { calls } = await run([status]);
    assert.deepEqual(calls, [['status', undefined]]);
  });
}

test('new work discovered after draining resumes the game', async () => {
  const { calls } = await run([{ ...idle }, { ...idle, connectedPlayers: 1 }]);
  assert.deepEqual(calls.at(-1), ['resume', 'POST']);
  assert.equal(calls.length, 4);
});

test('failed fencing resumes the game and never stops EC2', async () => {
  const { calls, error } = await run([{ ...idle }, { ...idle }], { fenceError: new Error('stale boot') });
  assert.match(error.message, /stale boot/);
  assert.deepEqual(calls.at(-1), ['resume', 'POST']);
  assert.equal(calls.some(call => call.constructor.name === 'StopInstancesCommand'), false);
});

test('failed EC2 stop remains fenced for operator reconciliation', async () => {
  const { calls, error } = await run([{ ...idle }, { ...idle }], { stopError: new Error('EC2 unavailable') });
  assert.match(error.message, /EC2 unavailable/);
  assert.equal(calls.at(-1).constructor.name, 'StopInstancesCommand');
});
