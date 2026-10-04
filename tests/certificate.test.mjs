import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, readFile, readlink, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { ensureCertificate, changeChallenge, verifyCertificate } from '../packetloss/runtime/certificate.mjs';

const config = { hostname: 'eu.game.example.com', zoneId: 'ZEXAMPLE', email: 'owner@example.com' };

/** Sign local CSRs with a temporary CA so certificate lifecycle tests never contact ACME. */
async function setup(t) {
  const directory = await mkdtemp(join(tmpdir(), 'packetloss-certificate-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const ca = join(directory, 'ca.pem');
  const caKey = join(directory, 'ca-key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=Local test CA', '-keyout', caKey, '-out', ca, '-days', '365'], { stdio: 'ignore' });
  const root = join(directory, 'tls');
  const clients = [];
  const createClient = options => {
    clients.push(options);
    return { async auto(options_) {
      assert.deepEqual(options_.challengePriority, ['dns-01']);
      const csr = join(directory, 'request.pem');
      const output = join(directory, 'signed.pem');
      await writeFile(csr, options_.csr);
      execFileSync('openssl', ['x509', '-req', '-in', csr, '-CA', ca, '-CAkey', caKey, '-CAcreateserial', '-out', output, '-days', '90'], { stdio: 'ignore' });
      return readFile(output, 'utf8');
    } };
  };
  return { root, clients, createClient };
}

test('issues a matching certificate/key pair and reuses a valid certificate', async t => {
  const options = await setup(t);
  assert.equal(await ensureCertificate(config, options), true);
  const current = join(options.root, 'current');
  verifyCertificate(await readFile(join(current, 'fullchain.pem')), await readFile(join(current, 'privkey.pem')), config.hostname);
  assert.equal((await stat(join(current, 'privkey.pem'))).mode & 0o777, 0o600);
  assert.equal(await ensureCertificate(config, options), false);
  assert.equal(options.clients.length, 1);
});

test('renewal failure preserves the selected certificate and persistent ACME identity', async t => {
  const options = await setup(t);
  await ensureCertificate(config, options);
  const before = await readlink(join(options.root, 'current'));
  const account = await readFile(join(options.root, 'account-key.pem'));
  await assert.rejects(ensureCertificate(config, {
    ...options, now: Date.now() + 61 * 86400000,
    createClient(clientOptions) {
      assert.deepEqual(clientOptions.accountKey, account);
      return { async auto() { throw new Error('ACME unavailable'); } };
    },
  }), /ACME unavailable/);
  assert.equal(await readlink(join(options.root, 'current')), before);
});

test('unexpected certificate host cannot replace an existing pair', async t => {
  const options = await setup(t);
  await ensureCertificate(config, options);
  const current = join(options.root, 'current');
  const pem = await readFile(join(current, 'fullchain.pem'));
  const key = await readFile(join(current, 'privkey.pem'));
  assert.throws(() => verifyCertificate(pem, key, 'other.example.com'), /validation failed/);
});

test('DNS challenges update only the configured record and wait for propagation', async () => {
  const calls = [];
  const waits = [];
  const route53 = { async send(command) { calls.push(command.input); return { ChangeInfo: { Id: '/change/owned' } }; } };
  for (const action of ['UPSERT', 'DELETE']) {
    await changeChallenge(route53, config, action, { identifier: { value: config.hostname } }, { type: 'dns-01' }, 'token', async (...args) => { waits.push(args); });
  }
  assert.deepEqual(calls.map(call => call.ChangeBatch.Changes[0].Action), ['UPSERT', 'DELETE']);
  assert.deepEqual(calls[0].ChangeBatch.Changes[0].ResourceRecordSet, { Name: `_acme-challenge.${config.hostname}`, Type: 'TXT', TTL: 30, ResourceRecords: [{ Value: '"token"' }] });
  assert.equal(waits.length, 2);
  assert.equal(waits[0][1].Id, '/change/owned');
  await assert.rejects(changeChallenge(route53, config, 'UPSERT', { identifier: { value: 'other.example.com' } }, { type: 'dns-01' }, 'token'), /Unexpected/);
  assert.equal(calls.length, 2);
});
