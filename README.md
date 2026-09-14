# infra

Infrastructure as code for the `hakimalai.com` public web stack.

This repo manages the shared infrastructure around the public sites while the
application repositories continue to own their source code, builds, and site content.

## Overview

`infra` is intentionally small. It keeps DNS, repository policy, and future
AWS resources in one audited Terraform project without mixing infrastructure
changes into the individual site repos.

## Managed Resources

- Route 53 records for `hakimalai.com`, `qr.hakimalai.com`, `packetloss.hakimalai.com`, and `dev.packetloss.hakimalai.com`.
- PACKETLOSS dev/prod S3 buckets, CloudFront distributions, HTTPS, and GitHub OIDC deployment roles.
- PACKETLOSS GitHub environments, branch restrictions, and per-stage deployment/build variables.
- A $5 monthly AWS budget with $2.50/$5 actual-spend alerts and a $5 forecast alert.
- GitHub repository rulesets for branch creation, pushes, and `main` protection.
- GitHub Actions permissions and the `production` environment for this repo.
- S3 and DynamoDB resources used by the Terraform remote backend.
- A reserved module boundary for future free-tier EC2 infrastructure.

## Repository Layout

```text
.
├── .github/workflows/     # Terraform check and apply workflows
├── backend/               # Backend bootstrap metadata and IAM policy
├── docs/                  # Operational and design notes
└── terraform/             # Terraform root module
```

## Delivery Model

PACKETLOSS deployment code lives in `.github/workflows/deploy-packetloss.yml`.
Once the caller migration is published, PACKETLOSS calls it after successful
CI, using a pinned infra commit. The run,
application checkout, environments, and OIDC identity belong to PACKETLOSS.
Publish the reusable workflow before updating the application's caller; see
the PACKETLOSS runbook for the ordered migration.

Pull requests run Terraform formatting and validation. Production changes are
applied by the manual `Terraform Apply` workflow from `main`, using the remote
S3 backend and GitHub Actions secrets.

The first workflow apply adopts the known existing DNS records and bootstrap
ruleset through Terraform import blocks. After that, Terraform owns the steady
state.

## Security

- Terraform state is stored remotely, not in Git.
- AWS credentials and GitHub tokens are stored as GitHub Actions secrets.
- Upstream branch creation and branch pushes are restricted to repository admins.
- Infrastructure deployments use protected `main` and the `production` environment;
  PACKETLOSS deployments use their matching `dev`/`prod` environment and branch.

## Documentation

- [Operations](docs/runbook.md)
- [Security notes](docs/security.md)
- [GitHub Pages DNS model](docs/github-pages.md)
- [PACKETLOSS deployment and budget](docs/packetloss.md)
