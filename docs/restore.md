# Restore runbook

Getting the irreplaceable data back: the EBS data volume, which holds users, IRC network configs, SQLite message logs, and uploads. The module has no media bucket; everything lives on this one volume.

This is the runbook for when data is lost, corrupted, or the workload account or region is gone. Building the backup pipeline is [cross-account-backup.md](cross-account-backup.md); putting a restored volume into service afterwards is [az-move.md](az-move.md). Every mechanical step below is `scripts/restore.sh`; run it with no arguments for the subcommand list. This page covers when to use which and what each does with your credentials.

Every command takes the Terraform root that instantiates the module: `--root <root>` before the subcommand, or `THELOUNGE_ROOT=<root>`. The root exports the module as the `thelounge` output, which the script reads for region, account, and vault names.

## Two accounts, two regions

Commands below use `<region>` and `<backup_region>` rather than literal regions; read them from your own stack.

| Placeholder | Where to look it up | Holds |
|---|---|---|
| `<region>` | the `region` module output | the local vault, the volume, the subnet |
| `<backup_region>` | the `backup_region` input, or the region field of the `backup_copy_vault_arn` output | the off-site vault |

```sh
terraform -chdir=<root> output -json thelounge | jq -r '.region, .backup_copy_vault_arn'
```

`scripts/restore.sh` reads both itself; the placeholders serve the raw `aws` commands on this page. `start-copy-job`, the mechanics behind `restore.sh copy-back`, is the one command that spans both: it runs with `--region <backup_region>` (where the source vault lives) while its `--destination-backup-vault-arn` names `<region>`.

`AWS_PROFILE` selects the workload account for every script. `BACKUP_PROFILE` selects the backup account and is needed by `copy-back`, `offsite`, `drill`, and `drill-cleanup`. A second account always means a second profile; nothing assumes a role.

## Where the copies are

| Copy | Lives in | Retention | Speed |
|---|---|---|---|
| Local vault (`vault_name` output) | workload account, `<region>` | `backup.retention_days` (7 by default) | fast; restore in place |
| Off-site vault (`backup_copy_vault_arn` output) | backup account (the workload account under `cross_region`), `<backup_region>` | `backup.remote_retention_days` | restore where it lives, or hours to copy back |
| `backup.sh snapshot` output | workload account, snapshots tagged `thelounge-data-ondemand` | none; never expires | fast |

The two vaults share the default name `thelounge-backup`; they are different resources in different accounts, told apart by whose credentials you use. `restore.sh list` shows both; the off-site one needs `BACKUP_PROFILE` under `cross_account`. `scripts/backup.sh status` covers the local vault and raw snapshots only.

## Pick a path

| Situation | Do this |
|---|---|
| Bad change in the last few days, account healthy | `restore.sh local`, or a `backup.sh snapshot` if you took one first |
| Local vault also corrupted, account healthy | `restore.sh copy-back` pulls the off-site copy home and restores it; budget hours |
| Workload account gone or compromised | `restore.sh offsite` restores where the copy already lives |
| Workload region gone, account fine (`cross_account`, `backup_region` differs from the module region) | `restore.sh offsite` needs only `BACKUP_PROFILE`; see [Region outage](#region-outage) |
| Rebuilding from scratch in a new account | `restore.sh offsite`, snapshot the result, and set the new deployment's `data_volume_snapshot_id` |
| Volume is fine, needs a different AZ | not a restore; see [az-move.md](az-move.md) |
| Proving the pipeline before locking the vault | `restore.sh drill`; see [Restore drill](#restore-drill) |

Restoring inside the backup account (`restore.sh offsite`) is the primary disaster path. AWS Backup cannot restore across accounts, so a copy in the backup account is restored where it lives, using the `thelounge-restore` role that account carries (keel's `backup-vault-account` module). If the workload account or region is gone, you are standing something up elsewhere regardless.

## Region outage

Under `backup.mode = "cross_account"` the destination vault's ARN is built from `backup_region`, not the module region (keel `modules/data-volume/backup.tf`). With `backup_region` set to a region other than the module's, every off-site copy sits outside a `<region>` outage as well as outside the workload account. `restore.sh offsite` touches only `BACKUP_PROFILE` and `<backup_region>`; it needs no workload credentials.

What a region outage does take out is `terraform apply` against the workload root, if its state bucket lives in the same region. Rebuilding is the same shape as any disaster rebuild: `restore.sh offsite`, snapshot the result, create a state bucket somewhere that is still up, and apply a fresh deployment there. State is reconstructible with `terraform import`; the volume is not, and it is already safe outside the failed region.

## Restore drill

`restore.sh drill` automates the restore drill that [cross-account-backup.md](cross-account-backup.md) requires before locking the destination vault. It seeds a recovery point, copies it off-site, confirms it landed with the backup account's own credentials, restores it to a scratch volume there, and runs the negative test: the workload account must get `AccessDeniedException` when it tries to delete from the destination vault. It needs `backup.mode = "cross_account"` and `BACKUP_PROFILE`, and refuses to run against a locked vault.

```sh
export AWS_PROFILE=<workload-account-admin>
export BACKUP_PROFILE=<backup-account-admin>
scripts/restore.sh --root <root> drill
```

Add `--with-contents <instance-id>` to also prove the restored contents match, not just that a restore job completed; see [Verify byte-for-byte](#verify-byte-for-byte-not-just-job-state). Skip it for a routine re-drill.

Run `restore.sh drill-cleanup` before locking the vault and before attaching the SCPs in [cross-account-backup.md](cross-account-backup.md#protecting-the-backup-account-with-scps). The drill creates real recovery points and a real scratch volume, and the SCP's `DeleteRecoveryPoint` deny blocks removing them whether or not the vault is locked. `drill` prints a manifest path (`restore-drill-<ts>.json` in the current directory; it is ignored by git and records what the drill touched), and `drill-cleanup` deletes each artifact, retrying only what is outstanding when run again:

```sh
scripts/restore.sh --root <root> drill-cleanup
```

A `DeleteRecoveryPoint` denied by an SCP is that scenario, not a bug. Every drill artifact carries a one-day retention, so a stuck one expires on its own. Lock the vault only after cleanup confirms clean (`restore.sh list` shows nothing left over).

### Verify byte-for-byte, not just job state

A `COMPLETED` restore job proves AWS Backup produced a volume, not that it matches what was live; an empty recovery point restores `COMPLETED` too. `restore.sh drill --with-contents <instance-id>` attaches the restored volume to an instance you already run in the backup account, mounts it over EC2 Instance Connect Endpoint SSH, and diffs a `sha256sum` manifest against one you took from the live volume:

```sh
# On the workload instance, before or during the drill:
sudo find /srv/thelounge/data -type f -exec sha256sum {} \; | sort >live-manifest.txt
```

Copy `live-manifest.txt` into your working directory before running the drill. The step is opt-in because the backup account deliberately has no VPC or compute of its own, so you need a scratch instance and an Instance Connect Endpoint there first. Run it once before the first lock, not on every re-drill. Tear the scratch instance and restored volume down once verified; `drill-cleanup` removes the volume `drill` created.

### Rebuilding a fresh deployment from a restored volume

`data_volume_snapshot_id` creates the data volume from an EC2 snapshot ID at first apply. It is the disaster-rebuild path for a new deployment, not a way to restore a live one (the volume is `prevent_destroy`; keel `modules/data-volume/main.tf` explains why); for a live deployment use [az-move.md](az-move.md).

`restore.sh offsite` produces a volume, not a snapshot. After restoring and verifying, snapshot the volume, then apply the new deployment in the backup account or copy the snapshot to the target account.

```sh
aws ec2 create-snapshot --region <backup_region> --volume-id <restored-vol-id> \
  --description "disaster rebuild source" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Project,Value=thelounge},{Key=Name,Value=thelounge-data-rebuild}]'
```

Then set it on the module:

```hcl
data_volume_snapshot_id = "snap-..."
```

Snapshots are region-scoped, not AZ-scoped, so the restored volume's AZ does not matter; the new deployment's subnet lands in the AZ the module picks or the `az` input pins. The instance role's attach grant is scoped to the volume Terraform creates, so no manual tagging is needed on this path.

## Restore into the workload account

The common case is a bad change in the last few days with the account healthy. `restore.sh local` restores straight from the local vault using the AWS Backup service role (`backup_role_name` output), which carries both the backup and restore service policies.

```sh
export AWS_PROFILE=<workload-account-admin>
scripts/restore.sh --root <root> local <recovery-point-arn>
```

It reads the recovery point's restore metadata (`get-recovery-point-restore-metadata`, patching in `availabilityZone`, which the API returns null), restores into the live subnet's AZ so the result can be adopted into the running instance, tags the volume `Project=thelounge` (the instance role's attach grant requires it), and prints the exact `azmove.sh adopt` command to run next.

If the local vault is also gone or corrupted but the account is healthy, `restore.sh copy-back` pulls the off-site recovery point into the local vault and then runs the same restore.

```sh
export AWS_PROFILE=<workload-account-admin>
export BACKUP_PROFILE=<backup-account-admin>
scripts/restore.sh --root <root> copy-back <recovery-point-arn>
```

### Copying back is much slower than copying out

Budget 4 to 6 hours, not minutes (documented AWS Backup behavior).

| Direction | Duration |
|---|---|
| workload to backup | a few minutes |
| backup to workload | 4 to 6 hours |

The job sits in `CREATED`, not `RUNNING`, for nearly all of it, with no status message. It looks hung; it is not. `restore.sh copy-back` says so before it starts and polls to completion.

- Do not draw conclusions from a short poll. Chasing SCPs, KMS grants, or service-linked roles wastes an afternoon on causes that are not real.
- Do not delete the destination vault while a job is queued; the job fails hours later with `Could not find backup vault`.
- If you need the data sooner, run `restore.sh offsite` and move the contents by hand.

## If a copy job failed

`FAILED`, or `Failed to unshare snapshot`, means a key grant is wrong. Start with the data volume key's `BackupAccountCopySnapshot` and `BackupAccountCreateGrant` statements (keel `modules/data-volume/main.tf`) and, for a copy back, the local vault's `AllowBackupAccountCopyBack` statement in the same file. Every KMS and vault-policy grant fails at runtime, not plan time; a plan proves nothing here.

## After a restore

- Verify the site loads and logging in works.
- Keep the pre-restore volume a few days as a rollback before deleting it.
- Re-prove the pipeline: `scripts/backup.sh --root <root> run "post-restore check"`.
