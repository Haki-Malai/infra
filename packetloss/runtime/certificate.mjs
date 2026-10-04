import acme from 'acme-client';
import { Route53Client, ChangeResourceRecordSetsCommand, waitUntilResourceRecordSetsChanged } from '@aws-sdk/client-route-53';
import { X509Certificate, createPrivateKey, createPublicKey, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

/** Confirm the certificate belongs to this host and its private key before installation. */
export function verifyCertificate(pem, key, hostname, now = Date.now()) {
  const certificate = new X509Certificate(pem);
  const expected = createPublicKey(createPrivateKey(key)).export({ type: 'spki', format: 'der' });
  if (certificate.checkHost(hostname) !== hostname || !certificate.publicKey.export({ type: 'spki', format: 'der' }).equals(expected) || Date.parse(certificate.validTo) <= now) {
    throw new Error('Certificate host, key or expiry validation failed.');
  }
  return certificate;
}

/** Update only the configured DNS-01 record and wait for Route53 propagation. */
export async function changeChallenge(route53, config, action, authz, challenge, value, wait = waitUntilResourceRecordSetsChanged) {
  if (challenge.type !== 'dns-01' || authz.identifier.value !== config.hostname) throw new Error('Unexpected ACME challenge.');
  const response = await route53.send(new ChangeResourceRecordSetsCommand({
    HostedZoneId: config.zoneId,
    ChangeBatch: { Changes: [{ Action: action, ResourceRecordSet: {
      Name: `_acme-challenge.${config.hostname}`, Type: 'TXT', TTL: 30,
      ResourceRecords: [{ Value: JSON.stringify(value) }],
    } }] },
  }));
  await wait({ client: route53, maxWaitTime: 180, minDelay: 2, maxDelay: 5 }, { Id: response.ChangeInfo.Id });
}

/** Persist the ACME identity and atomically select a complete certificate/key pair. */
export async function ensureCertificate(config, { root = '/etc/packetloss/tls', now = Date.now(), route53 = new Route53Client({ region: 'us-east-1' }), createClient = options => new acme.Client(options), wait } = {}) {
  await mkdir(root, { recursive: true, mode: 0o700 });
  const current = join(root, 'current');
  try {
    const [pem, key] = await Promise.all([readFile(join(current, 'fullchain.pem')), readFile(join(current, 'privkey.pem'))]);
    const certificate = verifyCertificate(pem, key, config.hostname, now);
    if (Date.parse(certificate.validTo) - now > 30 * 86400000) return false;
  } catch (error) {
    if (error.code !== 'ENOENT' && !error.message.startsWith('Certificate host, key or expiry')) throw error;
  }
  const accountFile = join(root, 'account-key.pem');
  let accountKey;
  try { accountKey = await readFile(accountFile); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    accountKey = await acme.crypto.createPrivateEcdsaKey();
    await writeFile(accountFile, accountKey, { mode: 0o600, flag: 'wx' });
  }
  const client = createClient({ directoryUrl: acme.directory.letsencrypt.production, accountKey });
  const [key, csr] = await acme.crypto.createCsr({ commonName: config.hostname });
  const pem = await client.auto({
    csr, email: config.email, termsOfServiceAgreed: true, challengePriority: ['dns-01'],
    challengeCreateFn: (authz, challenge, value) => changeChallenge(route53, config, 'UPSERT', authz, challenge, value, wait),
    challengeRemoveFn: (authz, challenge, value) => changeChallenge(route53, config, 'DELETE', authz, challenge, value, wait),
  });
  verifyCertificate(pem, key, config.hostname, now);
  const generation = join(root, randomUUID());
  await mkdir(generation, { mode: 0o700 });
  await writeFile(join(generation, 'privkey.pem'), key, { mode: 0o600 });
  await writeFile(join(generation, 'fullchain.pem'), pem, { mode: 0o644 });
  const next = join(root, `next-${randomUUID()}`);
  await symlink(generation, next);
  await rename(next, current);
  return true;
}

if (import.meta.main) {
  const config = JSON.parse(await readFile(process.argv[2], 'utf8'));
  const renewed = await ensureCertificate(config);
  if (renewed && process.argv.includes('--reload')) {
    execFileSync('nginx', ['-t'], { stdio: 'inherit' });
    execFileSync('systemctl', ['reload', 'nginx'], { stdio: 'inherit' });
  }
}
