# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Until 1.0.0, a minor release may include breaking changes.

## [Unreleased]

## [1.0.0] - 2026-11-04

### Added

- Reusable root module for [The Lounge](https://thelounge.chat/) on AWS: one instance, Spot or On-Demand, behind CloudFront with no public IPv4 address by default. The module declares no provider or backend configuration; the caller passes `aws` and `aws.us_east_1`.
- Required inputs are `domain_name`, `zone_id` (the existing public Route 53 hosted zone), and `alert_email`. `env` defaults to `prod` and `thelounge_version` to the tested release.
- Backups to a local vault, a second region, or a second AWS account; an optional `/summarize` and `/ask` catch-up on Amazon Bedrock; an optional operational status page.
- The instance acknowledges each release it applies: after `thelounge.service` is active, `thelounge-converge.sh` writes `deployed/current-<arch>.json` to the delivery bucket, and the instance role gains `s3:PutObject` on exactly `deployed/*`.
- `scripts/deploy.sh` waits for the delivery pipeline run of the applied release, then for the instance's acknowledgement, then for a 200 from the site, and exits non-zero naming the stage that timed out.
- Operator scripts (`deploy.sh`, `backup.sh`, `restore.sh`, `azmove.sh`) take the Terraform root that instantiates the module as `--root DIR` or `THELOUNGE_ROOT`, and read names, region, and account from its `thelounge` output. `azmove.sh adopt` prints the `az` to set on the module.
- `examples/minimal`, composing the module with the keel DNS, audit, and cost budget modules (v0.2.0).
- Contract tests for the root module and `modules/compute`, shell tests for the scripts, a hygiene check, and pre-commit and CI configuration.
- Runbooks for restore, cross-account backup, and AZ moves.

### Fixed

- A null `backup_copy_vault_arn` (backups local or disabled) reaches the status module as an empty string instead of failing the plan.

### Upgrade from the single-repo layout

A deployment that ran this stack as a root inside its own repository adopts the module without replacing resources:

1. Replace the old root's module blocks with one `module "thelounge"` call to this module, and export it with `output "thelounge" { value = module.thelounge }`.
2. Declare a `moved` block in your root for each resource address that gained the `module.thelounge.` prefix. keel's `dns`, `audit`, and `finops` modules stay in your root, so their addresses do not move.
3. Run `terraform plan` and confirm it shows moves only. Apply.
4. Run `sh scripts/deploy.sh --root <root>` from a checkout of this repository, so the instance acknowledges the release it is already running.

[Unreleased]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kjiwa/terraform-aws-thelounge/releases/tag/v1.0.0
