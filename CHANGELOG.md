# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/2.0.0/), and the project follows [Semantic Versioning](https://semver.org/). Until 1.0.0, a minor release may include breaking changes.

## [2.3.1] - 2026-11-22

### Fixed

- v2.3.0's non-empty `ident.servers` fails to apply: AWS refuses a `/128` IPv6 route through an internet gateway in a route table that has an egress-only gateway route (`OperationNotPermitted`). The per-address routes are gone. With `ident` on, the single `::/0` route moves to the internet gateway in both modes, and the security group alone decides inbound: tcp/113 from `::/0` with empty `servers`, from each resolved `/128` otherwise.

### Upgrade

- With `ident` off, no change.
- With `ident` on and empty `servers`, no change.
- With `ident` on and non-empty `servers`, the plan drops the failed `/128` routes (if any exist) and points `::/0` at the internet gateway in place.

## [2.3.0] - 2026-11-22

### Added

- `ident` (default off): runs The Lounge's identd on tcp/113 so IRC servers see the account name instead of a `~` username. Free: an internet gateway and its routes have no charge. Optional `ident.servers`: empty opens tcp/113 from `::/0` and moves the IPv6 default route to the internet gateway; hostnames get a `/128` route and a tcp/113 rule per resolved AAAA address, with `::/0` left on the egress-only gateway.
- The `hashicorp/dns` provider (`>= 3.4`) resolves `ident.servers` at plan time.

### Changed

- `thelounge_config` may not set `identd`: `ident` owns it.
- The Lounge's unit always carries `CAP_NET_BIND_SERVICE`, so it can bind tcp/113 as a non-root user.

### Upgrade

- `terraform init -upgrade` installs the dns provider.
- With `ident` off, the plan changes only the delivery bucket's unit file; the next converge tick installs it, and The Lounge loads it at its next restart (a release, a config change or a reboot).
- With `ident` on, the plan also rewrites `config.js`, whose change restarts The Lounge on the new unit, adds the ident rules, and, with empty `servers`, switches the IPv6 default route to the internet gateway in place.

## [2.2.0] - 2026-11-20

### Added

- A CloudFront response headers policy on the client, `/status/api` and the status page behaviors (the status module sets no headers): HSTS (one year, no subdomains or preload), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN` and a `frame-ancestors 'self'` CSP.

### Changed

- The status page is terraform-aws-status-page v0.9.0: 44 px touch targets, scoped captions, the running image's age, median recovery, and a read of the launch template versions for a pending newer image.

### Upgrade

- The plan also updates the status Lambda's code and policy.
- The plan adds one response headers policy and updates the distribution in place. CloudFront redeploys with no downtime expected, and no instance refresh starts.

## [2.1.1] - 2026-11-20

### Fixed

- The repoint Lambda no longer gives up when the instance-running event fires before the instance appears in `DescribeInstances`. In v2.1.0 that run logged `no-running-instance` and exited, and the next run was the 5-minute poll, so the first replacement left the site unreachable for about 9 minutes. An event-triggered run now looks again every 5 seconds for up to 90 seconds.
- The repoint poll is back to every minute, so a missed event costs at most a minute instead of five.
- The repoint Lambda's timeout is 900 s, its VPC origin deploy wait 270 s, and the lock and sweep grace 960 s, so the lookup wait fits inside the timeout.

### Upgrade

- `terraform init -upgrade`, then plan. The plan changes only the repoint Lambda and rule. It changes no launch template and starts no instance refresh.

## [2.1.0] - 2026-11-19

Upgrading with `ami_ids` null: the first plan adds the AMI updater (Lambda, role and policy, log group, schedule rule and target, two alarms), `terraform_data.image_pin`, the instant repoint rule and its permission, and updates both launch templates (new `user_data`), the group, the instance and repoint policies, the repoint rule and Lambda, and the delivery bucket's instance files. It plans no `image_id` change and no template replacement. The new `user_data` makes the group start one instance refresh, an outage of about 5 to 8 minutes while the new instance boots; nothing else triggers one.

### Added

- The keel `ami-updater` module (v0.4.0) runs when `ami_ids` is null. It writes a launch template version for each new Amazon Linux 2023 release once it is a day old and points the group at it; it replaces the instance only when the running AMI is over `ami_max_age_days` (new, default 14) old, with the group's refresh settings, and not while the site-down alarm fires. Its alarms notify the ops topic.
- Compute outputs `launch_template_ids` and `refresh_preferences`; monitoring output `outage_alarm_names`.
- The Spot drain, at the 2-minute notice, stops The Lounge and converge, detaches the data volume and marks the instance Unhealthy without waiting out the health check grace period, so the replacement launches at the notice instead of after EC2 terminates the instance. The instance policy gains `autoscaling:SetInstanceHealth` on the group, and `instance.env` exports `EBS_VOLUME_ID`.
- The repoint Lambda runs on an EventBridge rule for an instance entering `running`, so the CloudFront VPC origin follows a replacement within seconds instead of at the next poll.
- `data_volume_size_gb` is validated as a whole number from 1 to 16384.

### Changed

- The launch templates ignore `image_id`, so Terraform leaves the updater's versions alone; `terraform_data.image_pin` replaces the templates when `ami_ids` changes. The images are read from SSM only when `ami_ids` is null.
- `ami_ids` pins have no updater and no longer warn on every plan; the stale-pin `check` is removed.
- Repoint runs serialize on an SSM parameter lock (`/thelounge/edge/repoint-lock`), so overlapping runs no longer race on `UpdateDistribution`. A run that finds the lock held leaves a pending mark (`/thelounge/edge/repoint-pending`), and the holder makes one more pass before releasing, so an event during a run is not lost. The repoint role gains Get, Put and DeleteParameter on both.
- The repoint schedule is every 5 minutes, a safety net behind the event rule.
- `user_data` installs `jq` before fetching the instance files, starts the first converge as soon as `instance.env` exists instead of waiting for the timer, and installs `dnf-automatic` once the app is up (or after 10 minutes). The converge timer keeps its 2-minute first tick as the fallback and for a plain reboot.
- The `active` description states the sleeping cost, and the `data_volume_size_gb` description that EBS cannot shrink.
- Status-page modules v0.7.0 to v0.8.0.
- Terraform floors align with the sibling modules: aws provider `>= 6.45`, Terraform `>= 1.15` in every module.
- Outages are planned only for `deploy`, `instance-refresh` and `capacity-change`. `rightsize` and `backup` are matched by SSM markers this stack never writes, so they never matched.

### Upgrade

- `terraform init -upgrade`, then plan. Applying starts one instance refresh.
- A stack that pinned `ami_ids` keeps its pin and runs no updater.

## [2.0.0] - 2026-11-12

### Changed

- The rightsize watchdog uses the shared check from terraform-aws-keel v0.3.0, vendored as `scripts/keel/rightsize-check.sh` and installed as `keel-rightsize-check`. It replaces the instance when the cheapest eligible Spot pool costs at most 75% of the current type's price and the placement score is at least 5. Any API failure now leaves the instance in place; the old watchdog proceeded when the placement score was unavailable.
- The instance policy gains `autoscaling:DescribeAutoScalingGroups`, `ec2:DescribeSpotPriceHistory` and `ec2:GetInstanceTypesFromInstanceRequirements`, and `instance.env` exports `ASG_NAME`.
- The watchdog logs any check failure other than an ordinary decline.
- Uses terraform-aws-status-page v0.7.0.

### Removed

- `instance_requirements.preferred_types` and its validation. Callers that set `instance_requirements` must drop the key.

### Upgrade

- `terraform init -upgrade`, then apply. The launch template changes, so applying refreshes the instance. The availability schedule rule and its Lambda permission are replaced.

## [1.0.5] - 2026-11-11

### Fixed

- converge: a failed `systemctl restart` or `start` fails the tick again; 1.0.4 swallowed it while skipping the release record for a drained instance.
- repoint: an instance reporting no private DNS name is still repointed and swept; only the DomainName write is skipped.

## [1.0.4] - 2026-11-11

### Security

- The build role can no longer write `config/`, `desired/` or `deployed/`, or read `config/`. Its bucket-wide artifact-store grant had let a build step rewrite the config the instance installs as root and read `config/users.json`.
- The repoint role's distribution actions are scoped to the distribution, and Get/DeleteVpcOrigin to the account's VPC origins.
- `thelounge_config` rejects `public`, `reverseProxy`, `host` and `port`, which the stack pins. A caller that set one broke the security group and VPC origin contract silently; plans now fail with a message naming the keys.

### Fixed

- Converge no longer restarts thelounge after a Spot drain. The drain writes `/run/thelounge-drained` before stopping the unit, and converge leaves the unit alone while the marker exists, including when the drain fires mid-run.
- The pipeline-artifact expiry rule matches the 20-character prefix CodePipeline writes (`thelounge-delivery-p/`), so those objects expire after 7 days.
- The repoint Lambda also keeps both origins' `DomainName` at the running instance's private DNS name, so a Spot replacement no longer leaves a permanent plan diff. The repoint function runs on arm64.
- The data volume is formatted only when `blkid` reports no filesystem (exit 2); any other `blkid` failure aborts boot instead of formatting.

### Changed

- `node_version` defaults to 22.23.5.
- Uses terraform-aws-keel v0.2.1 and terraform-aws-status-page v0.3.2.
- `enable_public_ipv4` documents that the CloudFront-to-EIP hop is plain HTTP.

### Upgrade

- `terraform init -upgrade`, then apply. The default `node_version` change triggers a build and a new release; the repoint function is updated in place.

## [1.0.3] - 2026-11-04

### Fixed

- The status page's Spot recovery split times a reclaim from the interruption warning instead of the outage start, which read 0 s of capacity wait on every reclaim. `modules/status` and `modules/monitoring` use terraform-aws-status-page v0.3.1.

### Upgrade

- `terraform init -upgrade`, then apply. The availability and status Lambdas and the status page object change; nothing is replaced.

## [1.0.2] - 2026-11-04

### Fixed

- Usernames may contain `@` and `+`, so an email address works as a username. 1.0.1 rejected them.

## [1.0.1] - 2026-11-04

### Changed

- `thelounge_users` is sensitive, so plans no longer print password hashes, and its keys are validated: a username must start with a letter, digit or underscore and contain only letters, digits, underscores, dots and hyphens. The converge script skips any other name.

### Fixed

- Converge extracts a release into a staging directory and renames it into place, and repoints `current` with a rename, so a failed extraction or an interrupted tick never leaves a partial or missing release.
- A release that was activated but not started (the tick failed before the restart) is restarted on the next tick instead of being treated as running. The instance records the last started release in `/opt/thelounge/applied.sha`.
- Pruning keeps the release `current` points at, not the newest by modification time, so a rollback to a retained release is not pruned.
- Converge builds each user file with `jq` instead of `printf`, so a hash containing quotes or backslashes cannot corrupt it.
- The disk metric no longer aborts before the data volume is mounted; it reports `/` alone until then.
- The CloudFront repoint Lambda leaves an unreferenced VPC origin alone for 15 minutes so a concurrent run can still attach it, tolerates an origin deleted underneath it, and keeps its worst-case waits (2 x 300 s for the two VPC origins, 240 s for the distribution) inside its 870 s timeout.

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

[Unreleased]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.5...HEAD
[1.0.5]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/kjiwa/terraform-aws-thelounge/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/kjiwa/terraform-aws-thelounge/releases/tag/v1.0.0
