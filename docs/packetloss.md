# PACKETLOSS hosting and API

| Stage | Branch | URL | Build mode |
| --- | --- | --- | --- |
| dev | dev | https://dev.packetloss.hakimalai.com/ | development |
| prod | main | https://packetloss.hakimalai.com/ | production |

The corresponding API origins are `https://api.dev.packetloss.hakimalai.com`
and `https://api.packetloss.hakimalai.com`.

Both sites build at `/`. The dev gallery is `/dev/assets`, including direct
navigation and refresh; production has no gallery. CloudFront rewrites only
that known dev route to `index.html`, so missing assets still return errors.

Each stage has a private encrypted S3 bucket, CloudFront distribution, Cognito
Lite user pool, provisioned DynamoDB table, Lambda API, HTTP API Gateway, and
GitHub OIDC role. S3 permits public reads only through its own distribution.
TLS certificates are issued in `us-east-1`. There are no NAT gateways, paid
access logs, or separately provisioned WAF resources.

API capacity is fixed in `packetloss_stages`: dev uses 1 RCU, 1 WCU, and Lambda
concurrency 1; prod uses 4 RCU, 4 WCU, and concurrency 4. DynamoDB autoscaling is
not configured. Signup admission is capped at 5 per UTC day and 100 lifetime in
dev, and 30 per day and 1,000 lifetime in prod. API Gateway throttles are best
effort; capacity limits reduce blast radius but are not a hard spending cap.

## Variables and credentials

`terraform/packetloss-variables.tf` defines stage branch, subdomain, build mode,
and map selection. `terraform/packetloss-github.tf` publishes each stage's
`AWS_REGION`, `AWS_ROLE_ARN`, `S3_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID`, `SITE_URL`,
`BUILD_MODE`, `VITE_GAME_ENV`, `VITE_API_URL`, and `LAMBDA_FUNCTION_NAME` into its GitHub environment. These are public
configuration, not secrets. DEFAULT selects the normal map; DEMO selects the demo.

Environment policies restrict dev to the `dev` branch and prod to `main`.
Each OIDC trust policy restricts the repository, environment, and STS audience.
The deploy role can read/write only its own bucket, invalidate only its own
distribution, and update only its own API Lambda code; it cannot delete objects
or administer infrastructure. Dependency installation/build runs in a separate
job without OIDC permissions. CI calls
the reusable deployment workflow only after checks succeed, and PRs cannot deploy.

The `infra` Terraform workflow continues to use its existing credentials.
Its AWS principal needs the additional policies in
`backend/packetloss-iam-policy.json` and `backend/packetloss-api-iam-policy.json`
alongside the existing backend/DNS policy.
That template targets account `975050102915` and region `us-east-1`, as recorded
in the bootstrap policy; verify the actual principal/account before attachment.
Its CloudFront administration permissions cover distributions and origin access
controls in that account, because their IDs are assigned at creation. CloudFront
creation actions require wildcard resources; distribution creation is restricted
to the PACKETLOSS project tag.
Use a managed IAM policy for this supplement; it may exceed an IAM user's
inline-policy size limit when combined with the existing policy.

The GitHub Terraform token needs environment administration and Actions variable
write access on PACKETLOSS, in addition to its existing infra permissions.
Configure these infra Actions settings before running the workflow:

- Secret `BUDGET_ALERT_EMAIL`: the confirmed recipient.
- Optional variable `AWS_GITHUB_OIDC_PROVIDER_ARN`: reuse an existing GitHub OIDC
  provider, leaving it unset only if no provider exists.

The pipeline sets budget scope to `account`; no `BUDGET_SCOPE` variable is needed.
Deployment uses the pipeline's AWS credentials, without local AWS authentication.
For local Terraform configuration, the corresponding inputs are
`TF_VAR_budget_alert_email` and optional `TF_VAR_github_oidc_provider_arn`.
Do not commit credentials or a real recipient address. The `.tfvars.example`
file shows the configurable defaults; Terraform does not load it automatically.

## Budget behavior

The monthly budget is $5 USD. Email notifications trigger when actual cost
exceeds $2.50 or $5, and when forecasted cost exceeds $5. The confirmed scope is
the entire AWS account, including existing DNS and state backend costs. The
recipient remains a required secret supplied through `BUDGET_ALERT_EMAIL`.

The optional Terraform scope `packetloss` filters costs by `Project=packetloss` and activates that
cost allocation tag. Shared/untagged charges are not included in that filter.
AWS must discover the tag in billing before activation, which can take up to
24 hours after provisioning tagged resources, followed by up to 24 hours for
activation ([AWS tag activation](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html)).
For a new project, establish the
account budget first if approved, then switch scope after the tag is available;
do not apply project-only scope before checking `ce list-cost-allocation-tags`.

**This does not enforce a $5 maximum bill.** AWS Budgets uses delayed billing
data and does not stop CloudFront or S3 traffic. No automatic shutdown is
configured. This configuration uses CloudFront pay-as-you-go pricing, not a
flat-rate Free plan; `PriceClass_100` limits edge regions, not spending. If a
strict ceiling is required, resolve that requirement before provisioning.
See [AWS Budgets timing and limits](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
and [CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/).

S3 versions expire 30 days after becoming noncurrent; unfinished multipart
uploads expire after one day. Current assets do not expire, including earlier
hashed bundles kept for open sessions. Review their storage periodically; do
not expire all current objects, which would eventually delete a quiet live site.

The API keeps Lambda logs for seven days and sends Lambda error/throttle,
DynamoDB throttle, and unusual request-volume alarms to the budget email through
the `packetloss-api-alerts` SNS topic. The recipient must confirm the separate SNS
subscription email. Cognito's default sender remains in use, so its account-wide
daily email quota is also a signup and recovery constraint.

## Migration sequence

Every remote change requires the review and subsequent verification described
in AGENTS.md. These are operational steps, not authorization to execute them.

1. Verify AWS identity, remote Terraform state, the current Route 53 records,
   existing GitHub OIDC provider, and budget recipient/scope. The last observed
   apply and public DNS used PACKETLOSS A/AAAA records on GitHub Pages. Review
   drift and import existing resources where required before applying.
2. Review and attach both supplemental infrastructure IAM policies, configure the
   infra budget settings, and ensure the GitHub Terraform token can manage
   PACKETLOSS environments. Do not publish app workflows until these are ready.
3. Plan/apply with `packetloss_production_dns_enabled=false`. This provisions
   hosting, both API domains, accounts, fixed storage/compute capacity, alarms,
   environments, variables, and the budget while preserving
   production's GitHub Pages records. Review the plan for unrelated changes.
4. Publish `.github/workflows/deploy-packetloss.yml` in `Haki-Malai/infra` first.
   Obtain the full published commit SHA containing that file. In PACKETLOSS's
   CI, change only the deployment job's `uses` target to
   `Haki-Malai/infra/.github/workflows/deploy-packetloss.yml@<full-commit-SHA>`.
   Preserve `needs: [build, backend]`, the push/manual event guard, branch guard, `stage`
   input, and `contents: read`/`id-token: write` permissions. Remove the local
   `deploy-aws.yml` only with that caller change on **both** `dev` and `main`;
   remove any remaining `deploy-pages.yml` too. Run CI on each branch.
   The reusable workflow uses the caller's checkout SHA, environment variables,
   artifacts, and OIDC identity. Keep environments and IAM trust in PACKETLOSS;
   no dispatch token or infra environment migration is needed. Pin updates are
   separate from application merges: each merge deploys its new application SHA.
   It packages and updates the Lambda before publishing the site from the tested
   current SHA; superseded revisions are skipped. Keep
   the old gh-pages branch and Pages settings available for rollback. To roll
   back the workflow migration, restore the previous local workflow and caller
   together through the reviewed application workflow.
5. Obtain `packetloss_environments` from Terraform outputs. Check each API
   `/health` route, signup capacity response, email confirmation, login, profile
   update, idempotent record upload, local fallback, and logout. Check each
   distribution's HTTPS root and `/deployment.json`; verify the SHA and stage,
   referenced JS/CSS, and a model/maze asset. For the dev distribution, check
   `/dev/assets` and `/dev/assets/`. Before production DNS cutover, use the
   distribution hostname directly or curl's `--connect-to` with the production
   hostname to verify the custom certificate. Confirm root HTML has no `/prod`
   refresh or redirect. Browser QA requires a separate explicit request.
6. Plan/apply with `packetloss_production_dns_enabled=true` (workflow input
   `production_dns=cloudfront`), then check both
   custom domains, HTTPS, deployment metadata, and root asset loading again.
   Terraform persists the approved routing in the infra Actions variable
   `PACKETLOSS_PRODUCTION_DNS_ENABLED`. Subsequent workflow runs default to
   `production_dns=keep`; `pages` deliberately restores production's Pages DNS.
   Persist the same boolean value in local inputs if applying from a workstation.
7. Verify the budget amount, scope, and all notification subscribers using the
   Budgets API. A successful resource apply does not prove email delivery;
   check the recipient inbox when AWS sends an alert.

## Rollback

For application rollback, revert the faulty application change through the
normal reviewed Git workflow and rerun CI on the new branch head. Deployment
uploads assets first, publishes `index.html` last, and waits for invalidation.
The retained S3 object versions also permit an explicitly reviewed recovery.

For migration rollback, set `packetloss_production_dns_enabled=false` in the
next reviewed plan/apply to restore the GitHub Pages A/AAAA records. Keep the
old Pages content/settings until migration is accepted. Leave the new buckets
and distributions provisioned during recovery; buckets reject destruction
while nonempty. Dev continues to point to its own CloudFront distribution.

Remove obsolete Pages configuration only as a separately reviewed change.
