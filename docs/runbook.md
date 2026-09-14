# Operations

## Normal Flow

- Open a pull request for Terraform changes.
- Let the `Terraform Check` workflow validate formatting and syntax.
- Merge to `main` only after review.
- Run the manual `Terraform Apply` workflow from `main` for production changes.

For PACKETLOSS hosting, stage variables, budget inputs, and DNS cutover, follow
[the PACKETLOSS runbook](packetloss.md). The workflow's `production_dns` input
defaults to preserving the last approved routing.

## Bootstrap Status

- The public `Haki-Malai/infra` repository exists.
- The S3 state bucket and DynamoDB lock table exist.
- GitHub Actions secrets and the `AWS_REGION` variable are configured.
- The pre-push `restrict-branch-writes` ruleset exists and is represented in Terraform.

The first workflow apply adopts the existing Route 53 records and the bootstrap
ruleset through Terraform import blocks. After that, Terraform owns the steady
state.

## Changes

- DNS changes should be reviewed as production traffic changes.
- Repository ruleset changes should be reviewed as access-control changes.
- Workflow changes are intentionally restricted and should be rare.
- Future EC2 resources should stay isolated in a module until they are stable.

## Recovery

- DNS rollback: restore the previous Route 53 record values from AWS console
  history or from the workflow plan output.
- GitHub rules rollback: temporarily disable the affected repository ruleset
  in GitHub settings, revert the Terraform change, and re-apply from `main`.
- Backend rollback: keep the S3 bucket versioned; do not delete state objects.
