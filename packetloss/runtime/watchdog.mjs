/** Stop this region's fixed game instance after four hours, independently of the game process. */
import { EC2Client, DescribeInstancesCommand, StopInstancesCommand } from '@aws-sdk/client-ec2';
import { DynamoDBClient, GetItemCommand, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';

export const requestOptions = { maxAttempts: 1, requestHandler: { connectionTimeout: 2000, requestTimeout: 3000, throwOnRequestTimeout: true } };

/** Mark the owned boot stopping without allowing central outages to defeat the cap. */
export async function fenceInstance(instanceId, table, env, log = console.log) {
  try {
    const result = await table.send(new GetItemCommand({ TableName: env.CONTROL_TABLE, Key: marshall({ pk: 'SERVER' }), ConsistentRead: true }));
    const item = unmarshall(result.Item ?? {});
    if (item.instanceId !== instanceId || item.activeRegion !== env.GAME_REGION) return;
    await table.send(new UpdateItemCommand({
      TableName: env.CONTROL_TABLE, Key: marshall({ pk: 'SERVER' }),
      UpdateExpression: 'SET #phase = :stopping ADD revision :one',
      ConditionExpression: 'instanceId = :instance AND activeRegion = :region AND instanceRunId = :run',
      ExpressionAttributeNames: { '#phase': 'lifecycle' },
      ExpressionAttributeValues: marshall({ ':instance': instanceId, ':region': env.GAME_REGION, ':run': item.instanceRunId, ':stopping': 'stopping', ':one': 1 }),
    }));
  } catch (error) {
    log(`Control fence unavailable (${error.name}); enforcing independent uptime cap.`);
  }
}

/** Use EC2 launch time so application restarts cannot reset the deadline. */
export async function checkUptime({ env = process.env, ec2 = new EC2Client(requestOptions), table = new DynamoDBClient({ ...requestOptions, region: 'us-east-1' }), now = Date.now(), log = console.log } = {}) {
  const instanceId = env.INSTANCE_ID;
  const result = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
  for (const instance of (result.Reservations ?? []).flatMap(group => group.Instances ?? [])) {
    if (instance.State?.Name !== 'running') continue;
    if ((now - new Date(instance.LaunchTime).getTime()) / 1000 >= Number(env.MAX_UPTIME_SECONDS)) {
      await fenceInstance(instanceId, table, env, log);
      await ec2.send(new StopInstancesCommand({ InstanceIds: [instanceId] }));
      log(`Maximum uptime reached; stopping ${instanceId}.`);
    }
  }
  return { checked: instanceId };
}

/** Run the independent scheduled Lambda check. */
export async function handler() { return checkUptime(); }
