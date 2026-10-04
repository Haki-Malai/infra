# Private multiplayer operations

PACKETLOSS owns the TypeScript simulation/server and Node.js control Lambda.
This repository owns Terraform, host configuration and deployment operations.
Production uses Frankfurt (`eu-central-1`, `eu`) and N. Virginia (`us-east-1`,
`na`), one instance in each region, with at most one started through the control
API. Development remains local. The existing account/profile Lambda is retained.

## Review and first deployment

These instructions do not authorize remote changes. Follow AGENTS.md: present
exact commands, account/region/scope, risk and rollback, and obtain verification
in a subsequent message before each remote operation unless the user's exact
pre-approval suffix applies. Browser checks require a separate explicit request.

1. Verify account identity, existing state, both regional instance offerings and
   EC2 quotas, the production Cognito owner subject and the selected ARM AL2023
   AMI's minimum root volume. Default candidates are `t4g.micro`, Standard CPU
   credits, and an 8 GiB encrypted gp3 root. Benchmark with depleted credits before
   release. A four-player run must sustain 60 Hz with p99 simulation work below
   8 ms, no accumulating tick debt, and at least 200 MiB memory headroom. Test
   `t4g.small` against the same criteria if micro fails before proposing deployment.
2. Review additional Terraform principal permissions for EC2/VPC/EBS, SSM,
   instance profiles, regional Lambda/EventBridge/log groups, game tables and
   artifact storage. Existing account/API supplemental policies do not grant this
   complete set. Do not broaden the existing account Lambda's runtime role.
3. Supply infra Actions variable `GAME_SERVERS_ENABLED=true`, optional
   `GAME_SERVER_INSTANCE_TYPE`, secret `GAME_SERVER_OWNER_SUBJECTS_JSON` containing
   exactly one Cognito subject (a JSON array), and secret
   `GAME_SERVER_CERTIFICATE_EMAIL`. Keep the existing $5 account budget alerts.
   Local equivalents are the corresponding `TF_VAR_game_*` variables.
4. Run the reviewed infrastructure workflow. Its plan job has no protected apply
   environment. Review the generated plan before
   approving its separate apply job. The exact binary plan is encrypted in the
   private existing state bucket under `production/plans/`; the apply job checks
   its SHA256 and rejects plans older than 24 hours. No plan is uploaded as a
   GitHub artifact. Current objects are removed after apply; because the bucket is
   versioned, privately retained versions need a reviewed prefix-scoped lifecycle
   rule or periodic cleanup. Never apply a cleanup rule to Terraform state keys.
   Credentials and variables required to create the plan must therefore be scoped
   to the repository or another unprotected plan-only source; keep the production
   environment gate on the apply job.
5. EC2 cannot be created directly in a stopped state. Terraform creates Europe,
   waits for its SSM bootstrap marker, stops it once, then creates and stops North
   America. The complete bootstrap is gzip-compressed before EC2 user-data
   submission and Terraform rejects a compressed payload above the 16 KiB API
   limit. Bootstrap timeout fails the apply; inspect cloud-init/SSM and verify
   actual EC2 state before retrying. A failed bootstrap may remain running until
   the independent maximum-uptime watchdog runs. Runtime `state` changes are
   ignored after initial provisioning, so later applies do not shut down matches.
6. The control Lambda initially returns 503. Publish the bundled Node.js API package from
   PACKETLOSS to both the account Lambda and the separate control Lambda. The
   reusable site deploy workflow sets the control handler to
   `multiplayer.handler` on `nodejs22.x`. The account entrypoint is
   `account.handler`. Publish the versioned ARM
   server artifact and both regional boot manifests before an owner starts EC2.
7. Pin the published infra reusable workflow commit in PACKETLOSS's caller
   `.github/workflows/deploy-game-server.yml` (add it only after the infra workflow
   exists at a published commit; do not invent that SHA).
   `deploy-game-server.yml` must be called after successful application/server
   tests, from `main`, with `contents: read` and `id-token: write`. It builds on
   `ubuntu-24.04-arm`, publishes `server-dist/server.js` and `manifest.json`, then
   updates stopped-host manifests or drains/deploys a running host. It never
   starts EC2. `force: true` intentionally interrupts matches and requires review.

The caller can be a manual, main-only workflow using the template at
`PACKETLOSS/docs/deploy-game-server.yml.example`. Replace the reference with the
reviewed full published infra commit, copy it to
`PACKETLOSS/.github/workflows/deploy-game-server.yml`, and enable it only after
the relevant CI checks pass:

```yaml
jobs:
  deploy:
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: read
      id-token: write
    uses: Haki-Malai/infra/.github/workflows/deploy-game-server.yml@<FULL_PUBLISHED_INFRA_SHA>
    with:
      infra_ref: <FULL_PUBLISHED_INFRA_SHA>
      release_sha: ${{ inputs.release_sha }}
      force: ${{ inputs.force }}
      deploy_runtime: ${{ inputs.deploy_runtime }}
```

The instance AMI, instance type and user-data are creation-time inputs and
intentionally ignored after creation so an ordinary apply cannot restart or
resize a live game server. Decide the initial size from the benchmark before
provisioning. Later host configuration or size changes require an explicitly
reviewed maintenance operation or controlled instance replacement; changing a
Terraform variable or template does not silently reconfigure a running host.
Destruction is guarded, root volumes are retained, and replacement requires a
separate maintenance/rollback plan.

## Commands

After reviewing the remote operations, export the production API URL and an
existing Cognito access token privately for start. Do not put tokens in command
arguments, shell history, source files or logs. For AWS operations, use the
approved operator identity; EC2 starts should go through the control API.

```sh
export GAME_API_URL=https://api.packetloss.hakimalai.com
bash scripts/game-server status
bash scripts/game-server start --region eu
bash scripts/game-server start --region na
terraform -chdir=terraform output -json game_servers > /private/tmp/game-servers.json
export GAME_SERVER_CONFIG=/private/tmp/game-servers.json
bash scripts/game-server stop
bash scripts/game-server stop --force
bash scripts/game-server logs
bash scripts/game-server logs --region eu
```

`start` requires `GAME_SERVER_TOKEN` in the environment, submits an owner-authenticated
request, then polls readiness for ten minutes. It does not switch regions while
another instance is active. Stop the old instance and observe `stopped` before
starting the other. An uncertain previous start remains blocked for reconciliation;
lease expiry alone must never authorize starting the peer.

Normal `stop` invokes the control Lambda through an IAM-authorized operator event;
the Lambda runs a fixed SSM helper, drains admission, rejects active matches or
pending result writes, conditionally fences the current region/instance/run as
stopping, then stops EC2. A refusal leaves admission drained so existing matches
can finish before a retry. Neither the CLI nor the browser writes lifecycle state.
`--force` deliberately bypasses the match check; it still requires readable control
state and never terminates or deletes the instance. If control or EC2 APIs fail,
inspect and reconcile the existing operation instead of trying the other region.
An emergency direct EC2 stop is a separately reviewed action.

Stop and logs infer the active region; use `--region eu|na` to select one explicitly.
The operator identity needs `lambda:InvokeFunction` on the control Lambda and
read access to the regional CloudWatch log group. Its ordinary management role
does not need EC2 start/stop or DynamoDB write permissions.

## Host and protocol contract

- Public nginx accepts HTTPS/WSS on 443. Node binds `127.0.0.1:8080` with
  `/health`, `/ready`, `/ws`; administration binds only `127.0.0.1:8081` with
  `/internal/status`, `/internal/drain`, `/internal/resume`, `/internal/abort`.
- A persistent random `GAME_ADMIN_TOKEN` lives in root-owned
  `/etc/packetloss/server.env` (group-readable by the service only). Administrative
  requests require its bearer token; neither it nor instance credentials reach
  the browser. IAM instance roles provide AWS credentials through IMDSv2.
- Boot requires the central `SERVER` lease's `activeRegion`, `instanceId` and
  `instanceRunId` to match. It updates the regional Route53 A record to the new
  ephemeral IPv4, renews/obtains TLS through Route53 DNS-01, downloads the selected
  artifact, checks SHA256, and starts the service. Old expired certificates are
  renewed before readiness. DNS TTL is 30 seconds; status never equates running
  EC2 with a ready game process.
- Runtime receives `AWS_REGION=us-east-1`, `GAME_REGION=eu|na`,
  `GAME_INSTANCE_ID`, `GAME_INSTANCE_RUN_ID`, `GAME_CONTROL_TABLE`,
  `GAME_TICKETS_TABLE`, `GAME_RESULTS_TABLE`, `GAME_ALLOWED_ORIGINS`,
  `GAME_SNAPSHOT_HZ=20`, `GAME_MAX_UPTIME_MS=14400000`,
  `GAME_IDLE_TIMEOUT_MS=1200000`, and
  `GAME_OUTBOX_DIR=/var/lib/packetloss/outbox`.
  Node generates a fresh `processGeneration` every process start; the boot's
  original uptime deadline must survive application restarts.
- All three DynamoDB tables have string partition attribute `pk`. The control
  item is `SERVER`, ticket keys are SHA256 hashes of opaque tickets, and result
  keys are match IDs. Only temporary tickets/rate counters receive `expiresAt`.
  Durable results have no TTL. Never attach a TTL to the active lease.
- Completed results must enter `/var/lib/packetloss/outbox` durably before final
  acknowledgement and be retried to DynamoDB. Normal drain waits for
  `pendingResults=0`. Unfinished matches abort on process failure without a winner.

## Shutdown, rollback and verification

The local systemd idle timer requires no active matches, connected players or
pending results and at least 20 idle minutes. It drains, rechecks, fences the
current boot in DynamoDB, then stops only its own instance. Deployment holds a
local maintenance lock to prevent an idle stop midway through installation.
The independent regional Lambda checks EC2 launch time every minute and stops
its own instance after four hours. It attempts the same ownership fence but
still enforces the cap if the central control service is unavailable. The hard
deadline may therefore be exceeded by the check interval and bounded AWS API
latency; its one-attempt SDK timeouts leave time to call EC2 stop even when the
central DynamoDB fence is unavailable.
The application must warn players at 15/5/1 minutes and reject matches which
cannot finish by the deadline; a late join receives the existing deadline.

Application deployment keeps immutable releases under `/opt/packetloss/releases/`
and switches `/opt/packetloss/current` atomically. Normal deployment drains for up
to seven minutes; timeout resumes the old service and fails. Restart and readiness
checks have bounded deadlines which leave recovery time inside the 15-minute SSM
command limit, including a two-minute bound on artifact download. Failed readiness
restores the previous release and checks its readiness. The boot manifest is
updated only after a running deployment succeeds. A planned rollback selects an
earlier retained release artifact/checksum and runs the same reviewed deployment
procedure, then updates that region's `targets/<region>.json`; never edit a release
in place. Keep the current and previous release; periodically review old release
directories, artifact versions and log storage within the 8 GiB disk budget.

After reviewing the target S3 release and the exact workflow action under the
repository's remote-change gate, deploy a retained release through the production
environment with:

```sh
gh workflow run deploy-game-server.yml --repo Haki-Malai/PACKETLOSS --ref main \
  -f release_sha=<40-character-retained-PACKETLOSS-SHA> \
  -f deploy_runtime=true -f force=false
```

The workflow downloads that retained artifact and immutable release manifest,
verifies its SHA256, uses the same
drain/readiness/automatic-rollback procedure on a running instance, and changes
each stopped region's next-boot target without waking it. `force=true` is a
separate reviewed action that intentionally interrupts active matches.

Before release, verify both regions in sequence: ARM build, exhausted-credit load
test using the p99/debt/memory thresholds above, 50/100/200 ms RTT with jitter and
temporary disconnects, owner-only start, simultaneous competing starts, TLS/DNS after stop/start,
expired-certificate recovery, readiness timeout, single-use tickets, complete
2–4-player match and rematch, durable result retrieval, disconnects and aborts,
normal/forced stop, drain timeout, failed deployment rollback, 20-minute idle
shutdown and the independent uptime cutoff with Node stopped. Check that both
instances are stopped at the end. Local validation cannot establish any of these
remote lifecycle outcomes. Browser testing remains separately authorized.

During the four-player sizing run, query the localhost-only `/internal/status`
through a reviewed SSM command. Record `simulationWorkP99Ms`,
`maximumSimulationWorkMs`, `currentTickDebtMs`, `maximumTickDebtMs`,
`memoryAvailableBytes`, `residentSetBytes`, and `simulationWorkSamples` after at
least one sustained minute with Standard credits depleted. The micro acceptance
threshold is p99 below 8 ms, no growing current debt, and at least 200 MiB available;
repeat the identical run on `t4g.small` if any threshold fails.

Local checks:

```sh
npm --prefix packetloss ci
npm --prefix packetloss test
npm --prefix packetloss run build
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -input=false -lockfile=readonly
terraform -chdir=terraform validate
bash -n scripts/game-server terraform/modules/game-server/deploy.sh terraform/modules/game-server/control-stop.sh
```

Use Node.js 24 for these checks and the EC2 game process. Lambda runs Node.js 22,
which the existing shared AWS provider supports, and its bundles target Node.js
22. This migration does not upgrade the provider for unrelated infrastructure.
`packetloss/package-lock.json` pins the AWS SDK,
ACME and tar dependencies. The build bundles all dependencies into the watchdog
Lambda and EC2 management tools. Terraform puts the management ZIP in the private
game artifact bucket under its SHA256; bootstrap verifies that checksum before
installation. Keeping these bundles outside EC2 user data preserves its 16 KiB
limit. The reviewed Terraform plan bundle includes the management ZIP as well as
Lambda ZIPs, so apply uses the exact reviewed files.

`packetloss/dist/cloud.mjs` is the shared SDK-based operational CLI for the owner
commands, boot preparation and PACKETLOSS deployment workflows. Build it before
using `scripts/game-server`; these commands do not require the AWS CLI. New hosts
download the first management bundle with curl's native SigV4 and IMDSv2, passing
temporary credentials through stdin and verifying SHA256 before extraction.
Amazon Linux 2023 includes a sufficiently recent curl (SigV4 requires 7.75+).
The base OS package manager and this repository's shared Terraform state tooling
remain outside the application runtime migration.

The certificate helper uses Route53 DNS-01 and a persistent ACME account key.
It validates the issued hostname, private key and expiry, then atomically selects
a complete certificate/key pair in `/etc/packetloss/tls/current`. The 12-hour
timer renews certificates with at most 30 days left and reloads nginx; boot checks
the certificate before readiness. The certificate lock prevents issuance and
renewal overlap. Shutdown and deployment continue to share the maintenance lock.

## Node.js rollout from an existing installation

Local source changes do not upgrade provisioned resources. Keep application
deployment paused until the reusable infra workflows have been published and
the PACKETLOSS caller references their real, full commit SHA. Its old pinned
workflow expects the former backend package and must not be used for this release.
Do not substitute an unpublished SHA or an unreviewed branch reference.

1. Publish the reviewed infra workflow/runtime changes and update the PACKETLOSS
   reusable-workflow pins to that published commit in a coordinated release.
   Add `with.infra_ref` with the same full commit SHA at the same time. The
   workflows use it to checkout and bundle their deployment tools; rollback
   builds those tools while retaining the selected application release. Do not
   add this new input while a caller still targets the old workflow contract.
2. Build/test both repositories before the release. Review/apply Terraform to
   provision the Node.js 22 Lambda settings, scoped account deployment permission
   for `UpdateFunctionConfiguration`, and checksummed management artifact.
3. In the same maintenance window, publish the PACKETLOSS Node API bundle. The
   workflow sets `account.handler` and `multiplayer.handler` with `nodejs22.x`.
   Runtime changes and code uploads are separate operations: the old deployment
   may be unavailable between them. Verify both API handlers before reopening
   traffic. A rollback must restore the previous code *and* its matching runtime
   and handler together.
4. Existing EC2 instances deliberately ignore `user_data_base64` changes. They
   retain their old management tools until a separately reviewed host update or
   replacement installs the new management bundle, service units, preparation
   script and nginx configuration. Preserve the admin token, central boot lease,
   release selection and persistent outbox. Verify DNS/TLS, idle shutdown and
   the independent watchdog before claiming those hosts have been migrated.

These instructions describe rollout requirements and do not authorize deployment.

The planning estimate for two 8 GiB roots, 20 aggregate monthly `t4g.micro`
running hours, and the public IPv4 used during those running hours is approximately
$1.67–$1.69 before logs, artifacts, transfer, control/result storage, and existing
services. Recheck the
[Virginia price file](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.csv),
[Frankfurt price file](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/eu-central-1/index.csv),
and [public IPv4 pricing](https://aws.amazon.com/vpc/pricing/) immediately before
deployment. The existing $5 account budget is an alert, not a spending ceiling.

If an old local `.terraform` directory reconnects to a configured backend, use
a fresh `TF_DATA_DIR` for validation with `-backend=false`.
