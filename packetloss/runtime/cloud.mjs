/** Fixed PACKETLOSS cloud operations shared by provisioning, deployment and owner tools. */
import { S3Client, GetObjectCommand, PutObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import { LambdaClient, UpdateFunctionCodeCommand, UpdateFunctionConfigurationCommand, InvokeCommand, waitUntilFunctionUpdated } from '@aws-sdk/client-lambda';
import { CloudFrontClient, CreateInvalidationCommand, waitUntilInvalidationCompleted } from '@aws-sdk/client-cloudfront';
import { EC2Client, DescribeInstancesCommand } from '@aws-sdk/client-ec2';
import { SSMClient, SendCommandCommand, GetCommandInvocationCommand } from '@aws-sdk/client-ssm';
import { DynamoDBClient, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { Route53Client, ChangeResourceRecordSetsCommand, waitUntilResourceRecordSetsChanged } from '@aws-sdk/client-route-53';
import { CloudWatchLogsClient, FilterLogEventsCommand } from '@aws-sdk/client-cloudwatch-logs';
import { readFile, writeFile, readdir } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import mime from 'mime-types';

const clientTypes = { s3: S3Client, lambda: LambdaClient, cloudfront: CloudFrontClient, ec2: EC2Client, ssm: SSMClient, dynamodb: DynamoDBClient, route53: Route53Client, logs: CloudWatchLogsClient };

/** Construct clients only for the explicitly selected operation. */
function client(service, region = 'us-east-1') { return new clientTypes[service]({ region }); }

/** Upload assets before entrypoints while retaining previously deployed hashed files. */
export async function publishSite(s3, cloudfront, bucket, directory, distribution, wait = waitUntilInvalidationCompleted) {
  const files = [];
  async function collect(path, prefix = '') {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const key = `${prefix}${entry.name}`;
      if (entry.isDirectory()) await collect(join(path, entry.name), `${key}/`);
      else if (entry.isFile()) files.push(key);
    }
  }
  await collect(directory);
  for (const required of ['index.html', 'deployment.json']) if (!files.includes(required)) throw new Error(`Missing site entrypoint: ${required}`);
  const entrypoints = new Set(['index.html', 'deployment.json']);
  for (const key of [...files.filter(file => !entrypoints.has(file)).sort(), 'index.html', 'deployment.json']) {
    await s3.send(new PutObjectCommand({
      Bucket: bucket, Key: key, Body: await readFile(join(directory, key)),
      ContentType: mime.lookup(key) || 'application/octet-stream',
      CacheControl: entrypoints.has(key) ? 'no-cache,no-store,must-revalidate' : 'public,max-age=300',
    }));
  }
  const result = await cloudfront.send(new CreateInvalidationCommand({
    DistributionId: distribution,
    InvalidationBatch: { CallerReference: randomUUID(), Paths: { Quantity: 1, Items: ['/*'] } },
  }));
  await wait({ client: cloudfront, maxWaitTime: 1200 }, { DistributionId: distribution, Id: result.Invalidation.Id });
}

/** Dispatch one supported operation; arguments remain data passed to the SDK. */
export async function runCloud(args, { getClient = client, print = console.log, waitLambda = waitUntilFunctionUpdated, waitDns = waitUntilResourceRecordSetsChanged, waitInvalidation = waitUntilInvalidationCompleted, now = Date.now() } = {}) {
  const [operation, ...values] = args;
  const counts = { 's3-get': 3, 's3-put': 3, 's3-head': 2, 'lease-get': 1, 'dns-change': 2, 'ec2-state': 2, 'ssm-command': 3, 'ssm-status': 3, 'lambda-deploy': 3, 'lambda-invoke': 3, 'site-publish': 3, 'logs-tail': 2 };
  if (values.length !== counts[operation] || values.some(value => !value)) throw new Error(`Unsupported operation or arguments: ${operation}`);
  switch (operation) {
    case 's3-get': {
      const [bucket, key, file] = values;
      const response = await getClient('s3').send(new GetObjectCommand({ Bucket: bucket, Key: key }));
      await pipeline(response.Body, createWriteStream(file));
      return;
    }
    case 's3-put': {
      const [bucket, key, file] = values;
      await getClient('s3').send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: createReadStream(file), ContentType: mime.lookup(file) || 'application/octet-stream' }));
      return;
    }
    case 's3-head': {
      const [bucket, key] = values;
      await getClient('s3').send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
      return;
    }
    case 'lease-get': {
      const response = await getClient('dynamodb').send(new GetItemCommand({ TableName: values[0], Key: { pk: { S: 'SERVER' } }, ConsistentRead: true }));
      print(JSON.stringify(response));
      return;
    }
    case 'dns-change': {
      const route53 = getClient('route53');
      const response = await route53.send(new ChangeResourceRecordSetsCommand({ HostedZoneId: values[0], ChangeBatch: JSON.parse(await readFile(values[1], 'utf8')) }));
      await waitDns({ client: route53, maxWaitTime: 180, minDelay: 2, maxDelay: 5 }, { Id: response.ChangeInfo.Id });
      return;
    }
    case 'ec2-state': {
      const response = await getClient('ec2', values[0]).send(new DescribeInstancesCommand({ InstanceIds: [values[1]] }));
      print(response.Reservations?.[0]?.Instances?.[0]?.State?.Name ?? 'unknown');
      return;
    }
    case 'ssm-command': {
      const response = await getClient('ssm', values[0]).send(new SendCommandCommand({ InstanceIds: [values[1]], DocumentName: 'AWS-RunShellScript', Parameters: { commands: [values[2]], executionTimeout: ['900'] } }));
      print(response.Command.CommandId);
      return;
    }
    case 'ssm-status': {
      const response = await getClient('ssm', values[0]).send(new GetCommandInvocationCommand({ CommandId: values[1], InstanceId: values[2] }));
      print(response.Status);
      return;
    }
    case 'lambda-deploy': {
      const lambda = getClient('lambda', process.env.AWS_REGION ?? 'us-east-1');
      const [functionName, file, handler] = values;
      if (!['account.handler', 'multiplayer.handler'].includes(handler)) throw new Error('Unsupported PACKETLOSS handler.');
      await lambda.send(new UpdateFunctionCodeCommand({ FunctionName: functionName, ZipFile: await readFile(file) }));
      await waitLambda({ client: lambda, maxWaitTime: 300 }, { FunctionName: functionName });
      await lambda.send(new UpdateFunctionConfigurationCommand({ FunctionName: functionName, Runtime: 'nodejs22.x', Handler: handler }));
      await waitLambda({ client: lambda, maxWaitTime: 300 }, { FunctionName: functionName });
      return;
    }
    case 'lambda-invoke': {
      const [functionName, payload, file] = values;
      const response = await getClient('lambda').send(new InvokeCommand({ FunctionName: functionName, Payload: Buffer.from(payload) }));
      await writeFile(file, response.Payload ?? Buffer.alloc(0));
      print(JSON.stringify({ FunctionError: response.FunctionError }));
      return;
    }
    case 'site-publish':
      await publishSite(getClient('s3'), getClient('cloudfront'), ...values, waitInvalidation);
      return;
    case 'logs-tail': {
      const logs = getClient('logs', values[0]);
      let nextToken;
      do {
        const response = await logs.send(new FilterLogEventsCommand({ logGroupName: values[1], startTime: now - 3600000, nextToken }));
        for (const event of response.events ?? []) print(`${new Date(event.timestamp).toISOString()} ${event.message?.trimEnd() ?? ''}`);
        if (response.nextToken === nextToken) break;
        nextToken = response.nextToken;
      } while (nextToken);
    }
  }
}

if (import.meta.main) await runCloud(process.argv.slice(2));
