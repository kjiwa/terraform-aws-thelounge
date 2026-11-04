# AZ move runbook

Moving the data volume, subnet, and instance to a different availability zone. Use this when the pinned AZ is durably impaired (an extended Spot stockout across your whole instance set, or an AZ-level service problem). A short Spot gap clears on its own and does not need it.

`azmove.sh` automates the mechanical work and stops where you must decide or review. It never lets Terraform destroy the data, and your original volume survives the whole move as a fallback.

## Why this is fiddly

The volume and subnet are AZ-pinned, and AZ is immutable on both, so Terraform can only change it by replacing the resource. The volume's `prevent_destroy` correctly blocks that. So the move is: snapshot the live volume, restore it into the new AZ out-of-band, swap that volume into Terraform state, then apply the subnet and instance change. The original volume is removed from state, not deleted, and stays in AWS until you delete it by hand.

Not AZ-bound and needing no attention: S3, DNS, CloudFront, ACM, and all IAM. With `enable_public_ipv4` set, the Elastic IP is not AZ-bound either; it re-associates to whichever instance boots next.

## Prerequisites

- `aws`, `terraform`, `jq`, and `curl` on PATH; credentials for the deployment's account.
- The deployment is applied, and its root exports the module as the `thelounge` output, so `terraform -chdir=<root> output -json` includes it.
- Every command takes the root that instantiates the module: `--root <root>` before the subcommand, or `THELOUNGE_ROOT=<root>`. Region and account come from the module's outputs. Terraform inherits `TF_DATA_DIR` and `TF_CLI_ARGS_*` from the environment, so a root with a non-default data directory or required variables works by setting them (`adopt` runs `terraform import`, which evaluates the configuration: set `TF_CLI_ARGS_import=-var-file=...`).
- State backups land in the current directory as `azmove-state-<ts>.json`.

## Step 1: choose the AZ (manual)

```sh
scripts/azmove.sh --root <root> score
```

Prints the Spot placement score (1 to 10, higher is better) per AZ for the instance types the ASG allows, read live from its mixed-instances policy across both architectures. Pick the highest. The score is account- and time-specific and is a likelihood, not a guarantee. Override the type list with `INSTANCE_TYPES="t4g.nano t4g.micro ..."` to score a different set.

## Step 2: prepare (automated; takes the site down)

```sh
scripts/azmove.sh --root <root> prepare <az>
```

Scales the ASG to 0 (the site goes down and the volume detaches), snapshots the detached volume, and restores a new gp3 volume from the snapshot in the target AZ, tagged `Project=thelounge` (the instance role cannot attach it otherwise). Prints the new volume ID. The original volume is untouched. You confirm before anything destructive happens; the snapshot wait can take several minutes.

## Step 3: adopt (automated; state surgery, gated)

```sh
scripts/azmove.sh --root <root> adopt vol-0newvolume <az>
```

Backs up Terraform state to `azmove-state-<timestamp>.json`, checks the new volume (right AZ, right tag), finds the volume's state address (the one ending `module.storage.module.data_volume.aws_ebs_volume.this`, whatever your root named the module), removes the old volume from state (the AWS resource stays), and imports the new one at the same address. You confirm before the state edit.

It does not touch your configuration. After an AZ move, set `az = "<az>"` on the module in your root before planning; after a re-key, leave `az` as it is.

## Step 4: review and apply (manual; do not skip)

```sh
terraform -chdir=<root> plan
```

Confirm in the plan:

- the data volume is a no-op; if it shows as destroyed, stop and restore state from the backup;
- the subnet is replaced (it is empty now, so that is safe);
- the launch template gets a new version and the `AttachVolume` and `DetachVolume` IAM policy updates to the new volume ARN.

Then:

```sh
terraform -chdir=<root> apply
```

Apply must precede scale-up. The attach policy is scoped to the volume's ARN, and until apply updates it a launching instance is denied the attach.

## Step 5: finish (automated)

```sh
scripts/azmove.sh --root <root> finish https://<your-chat-hostname>/
```

Scales the ASG back to 1, waits for an InService instance, and, if you pass a URL, polls it until healthy. There is no deploy step: the new instance's `thelounge-converge.timer` fires within a few minutes of boot and pulls the last-built release, so allow a few minutes before the health poll succeeds. The instance attaches the restored volume, finds the existing filesystem by NVMe controller serial, and mounts the data.

Reaching the new instance is automatic. By default (zero IPv4) the edge module's repoint Lambda reconciles the CloudFront VPC origin against the running instance every minute; allow up to a minute plus CloudFront's deploy time. With `enable_public_ipv4 = true`, user-data associates the Elastic IP with the new instance at boot.

## Step 6: clean up (manual)

After a few days of confidence:

```sh
aws ec2 delete-volume --region <region> --volume-id vol-0oldvolume
```

The script never deletes the old volume; it is your rollback until you are sure.

## Rollback

Nothing destroys data before Step 4. Until you apply:

- The original volume and the snapshot both still exist.
- To abandon the move: `terraform -chdir=<root> state push azmove-state-<timestamp>.json` restores the pre-adopt state. Then revert `az`, scale the ASG back to 1, and delete the restored volume from Step 2.

After a failed apply the original volume is still intact; re-point state at it the same way and re-apply.

## Recovery time

Minutes, not seconds: the snapshot in Step 2 and the on-boot converge run in Step 5 dominate. It is a deliberate, gated procedure, not a hot failover.
