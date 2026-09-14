# Security Notes

## Repository Access

The repository is public so GitHub Actions and GitHub Pages can stay on the
free public-repo path. Public visibility does not grant write access.

## Main Branch

Terraform creates a repository ruleset for `main` that:

- Requires pull requests.
- Requires the `Terraform Check` status check.
- Requires branches to be up to date.
- Blocks branch deletion and force pushes.
- Requires linear history.
- Allows only the `Haki-Malai` user bypass in GitHub, so the owner can recover
  or publish direct changes when needed.

## Branch Creation and Pushes

Terraform also creates an all-branches ruleset that:

- Blocks branch creation unless the actor is the `Haki-Malai` user bypass.
- Blocks pushes to branches unless the actor is the `Haki-Malai` user bypass.
- Still leaves `main` protected by the stricter PR/status-check ruleset for
  non-admin actors.

For this personal public repo, public users cannot create upstream branches or
push. The `Haki-Malai` user bypass is the only configured ruleset bypass.

## Deployment

The apply workflow only runs when `github.ref` is exactly `refs/heads/main`.
The job also uses the `production` environment, which is restricted to protected
branches by Terraform.

PACKETLOSS's separate application pipeline uses the `dev` and `prod` environments,
restricted to `dev` and `main` respectively. Short-lived AWS OIDC credentials
grant publishing access only to the corresponding stage's bucket and distribution.
The build job has no OIDC permission; the publishing job installs no dependencies.
See [PACKETLOSS hosting](packetloss.md) for the infrastructure principal's
additional permissions and migration requirements.

## Secrets

PR workflows do not receive AWS or GitHub administration secrets. The PR
workflow performs only `terraform fmt`, provider init with `-backend=false`,
and `terraform validate`.

## Workflow Backdoors

GitHub push rulesets are only available for organization-owned repositories and
cannot be used by this personal public repository. Workflow changes should stay
rare, reviewed, and protected by the `main` pull request ruleset.

## Provider Gap

GitHub repository rulesets support user-specific bypass actors through the REST
API, but the Terraform GitHub provider does not currently support `User` as a
repository ruleset bypass actor. Terraform ignores ruleset bypass actor drift so
the `Haki-Malai` user bypass can be maintained through the GitHub API without
being reverted by later applies.

## Known Limit

GitHub cannot prevent repository admins from changing repository settings.
The design removes ordinary bypass paths, but admin access remains inherently
powerful.
