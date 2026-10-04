/** Drain and stop this instance after twenty minutes without active sessions. */
import { DynamoDBClient, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { EC2Client, StopInstancesCommand } from '@aws-sdk/client-ec2';
import { marshall } from '@aws-sdk/util-dynamodb';

/** Read the loopback-only service using the disk-local owner token. */
export async function admin(path, method = 'GET', env = process.env) {
  const response = await fetch(`http://127.0.0.1:8081/internal/${path}`, {
    method, headers: { Authorization: `Bearer ${env.GAME_ADMIN_TOKEN}` }, signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error(`Admin request failed: ${response.status}`);
  return response.json();
}

/** Reserved connections and undelivered results keep the instance alive. */
export function isIdle(status) {
  return status.activeMatches === 0 && status.connectedPlayers === 0 && status.pendingResults === 0 && status.idleMs >= 1_200_000;
}

/** Fence the current boot before stopping only its own EC2 instance. */
export async function stopIfIdle({ env = process.env, request = (path, method) => admin(path, method, env), table = new DynamoDBClient({ region: 'us-east-1' }), ec2 = new EC2Client({ region: { eu: 'eu-central-1', na: 'us-east-1' }[env.GAME_REGION] }) } = {}) {
  if (!isIdle(await request('status'))) return;
  await request('drain', 'POST');
  if (!isIdle(await request('status'))) { await request('resume', 'POST'); return; }
  try {
    await table.send(new UpdateItemCommand({
      TableName: env.GAME_CONTROL_TABLE, Key: marshall({ pk: 'SERVER' }),
      UpdateExpression: 'SET #phase = :stopping ADD revision :one',
      ConditionExpression: 'activeRegion = :region AND instanceId = :instance AND instanceRunId = :run AND #phase IN (:ready, :draining)',
      ExpressionAttributeNames: { '#phase': 'lifecycle' },
      ExpressionAttributeValues: marshall({ ':region': env.GAME_REGION, ':instance': env.GAME_INSTANCE_ID, ':run': env.GAME_INSTANCE_RUN_ID, ':stopping': 'stopping', ':ready': 'ready', ':draining': 'draining', ':one': 1 }),
    }));
  } catch (error) { await request('resume', 'POST'); throw error; }
  // A failed stop remains visibly fenced as stopping for operator reconciliation.
  await ec2.send(new StopInstancesCommand({ InstanceIds: [env.GAME_INSTANCE_ID] }));
}

if (import.meta.main) await stopIfIdle();
