# Cross-account backup

How the EBS data volume (users, IRC network configs, SQLite message logs, uploads) ends up with a copy a different AWS account owns: one the workload account cannot reach into and delete, even if its own credentials are compromised. `local` and `cross_region` leave every copy owned by the workload account. A copy in a vault whose policy grants the source account nothing but `backup:CopyIntoBackupVault` survives that. The cost is about 2.25 USD a month over `local`, almost entirely two KMS keys at about 1 USD each.

`cross_account` also gives `cross_region`'s protection for free when `backup_region` differs from the module's region: the destination vault ARN is built from `backup_region` regardless of which account owns it (keel `modules/data-volume/backup.tf`), so the copy survives losing the workload account and its region. See [Region outage](restore.md#region-outage).

Do not lock the destination vault until the restore drill in step 6 proves the copy pipeline end to end. Locking a vault whose backups you have not verified can leave you paying to store recovery points you cannot delete.

For a new deployment that chose `backup.mode = "cross_account"` at first apply, the volume is born on the customer-managed key and everything below applies as written. For an existing `local` or `cross_region` deployment, also do the [appendix](#appendix-migrating-from-local-or-cross_region) between steps 4 and 5.

Placeholders: `<root>` is the Terraform root that instantiates the module in the workload account, `<backup-root>` the root for the backup account, and `<backup_region>` the module's `backup_region` input, which must be the region of the backup account's own provider. The scripts take the workload root as `--root <root>`, or `THELOUNGE_ROOT`.

## Prerequisites

- `aws`, `terraform`, and `jq`.
- A workload root that exports the module as an output (`output "thelounge" { value = module.thelounge }`), which the scripts read.
- Admin credentials for three accounts: the Organizations management account, the workload account, and the backup account.
- The backup account exists and is in the same organization as the workload account. AWS Backup cross-account copy is organization-only.

## 1. Confirm cross-account backup is enabled organization-wide

Only the Organizations management account can enable it:

```sh
AWS_PROFILE=<management-account-profile> aws backup describe-global-settings \
  --query 'GlobalSettings.isCrossAccountBackupEnabled'
# expect: "true"
```

If it returns `"false"`, enable it from the management account with `aws_backup_global_settings` setting `isCrossAccountBackupEnabled = "true"`. This repository has no root for the management account.

## 2. Backup account: state bucket

The backup account needs its own Terraform state, in its own account. Pointing it at the workload account's bucket would invert the isolation this exercise creates.

In `<backup-root>`, a root with its own AWS provider for the backup account (pin `allowed_account_ids` to it, so the wrong `AWS_PROFILE` fails instead of building the bucket elsewhere):

```hcl
module "state" {
  source      = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/state-bucket?ref=v0.2.1"
  bucket_name = "<state-bucket>"
}
```

Create the bucket by hand (the module manages the bucket its own state lives in), point a partial `backend "s3" {}` at it, then import and apply:

```sh
export AWS_PROFILE=<backup-account-admin>
aws s3api create-bucket --bucket <state-bucket> --region <backup_region> \
  --create-bucket-configuration LocationConstraint=<backup_region>

terraform -chdir=<backup-root> init -backend-config=backend.hcl
terraform -chdir=<backup-root> import module.state.aws_s3_bucket.tfstate_web <state-bucket>
terraform -chdir=<backup-root> apply
```

Leave `encrypt` and `kms_key_id` out of the backend configuration; they would override the bucket's default encryption. Keep one `TF_DATA_DIR` per root, or pass `-reconfigure` when switching between the workload and backup roots.

An SCP on the backup account's OU that denies `s3:PutLifecycleConfiguration` makes this step fail with AccessDenied. The backup account holds no backup data in S3 (AWS Backup keeps EBS recovery points as native snapshots), so drop the action or scope the statement with `NotResource` on the state bucket.

## 3. Backup account: vault and key

Add keel's `backup-vault-account` module to `<backup-root>`:

```hcl
module "backup_vault" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/backup-vault-account?ref=v0.2.1"

  name_prefix                   = "thelounge"
  vault_name                    = "thelounge-backup"
  source_account_id             = "<workload-account-id>"
  vault_reader_source_role_name = "thelounge-status"
}
```

```sh
export AWS_PROFILE=<backup-account-admin>
terraform -chdir=<backup-root> apply
```

`name_prefix` must be `thelounge`: `scripts/restore.sh` and the status page address the restore and vault-reader roles by that name. The module creates the vault, its key (mandatory: the AWS-managed `aws/backup` key has an immutable policy that cannot be shared), the vault policy granting the workload account `backup:CopyIntoBackupVault` and nothing else, and the vault-reader role the status page's Backups panel assumes to read the vault's lock state.

Leave `vault_lock.mode` at `"none"` (the default) for now. Step 6 turns it on after the pipeline works.

`vault_name` here and `backup.dest_vault_name` on the workload module are a contract: the workload stack constructs the destination vault's ARN from account, region, and name rather than taking one pasted in. A mismatch is a runtime copy-job failure, not a plan error.

## 4. Workload account: set the mode and apply

Set `backup` on the module in `<root>`:

```hcl
backup = {
  mode                  = "cross_account"
  account_id            = "<backup-account-id>"
  remote_retention_days = 30
}
```

```sh
export AWS_PROFILE=<workload-account-admin>
terraform -chdir=<root> apply
```

On a new deployment's first apply the data volume is created directly on the customer-managed key, so there is nothing to migrate. The destination vault's ARN is the `backup_copy_vault_arn` output.

## 5. Seed the first recovery point

Do not wait until 03:00 UTC to find out whether any of this works:

```sh
export AWS_PROFILE=<workload-account-admin>
scripts/backup.sh --root <root> run "seed cross-account pipeline"
```

Use the workload account's admin profile; reading Terraform outputs decrypts state, which a read-only profile cannot do. `run` backs up the volume, waits, then copies the recovery point across with the retention the live plan sets, so the seeded point expires like a nightly one. Expect minutes. `scripts/backup.sh --root <root> status` shows the local side; it cannot show the far side, which needs the destination account's credentials. The drill below does that.

## 6. Verify, then lock (do not skip)

A plan proves nothing here. Every KMS grant in this design fails at runtime, and a misconfiguration looks like success until the copy job runs. `scripts/restore.sh drill` ([restore.md](restore.md)) is this step, automated: it seeds a recovery point, copies it off-site, confirms it landed using the backup account's credentials, restores it to a scratch volume there, and runs the negative test.

```sh
export AWS_PROFILE=<workload-account-admin>
export BACKUP_PROFILE=<backup-account-admin>
scripts/restore.sh --root <root> drill
```

`FAILED`, or `Failed to unshare snapshot`, on the copy step means a key grant is wrong; start with the volume key's `BackupAccountCopySnapshot` and `BackupAccountCreateGrant` statements (keel `modules/data-volume/main.tf`).

Add `--with-contents <instance-id>` once, before the first lock, to diff the restored volume's contents against the live one; see [Verify byte-for-byte](restore.md#verify-byte-for-byte-not-just-job-state).

The negative test is part of the drill: the workload account attempts `delete-recovery-point` against the destination vault and must get `AccessDeniedException`. A drill that reports this as a failure, meaning the delete succeeded, means the isolation this design exists for is not real. Stop and fix the vault policy before going further.

Run `scripts/restore.sh --root <root> drill-cleanup` before locking. The drill's recovery points and scratch volume are real; once the vault is locked and the SCPs are in place, nothing removes them until the SCP is detached.

### Protecting the backup account with SCPs

Attach these after a `drill` and `drill-cleanup` cycle has run clean, not before. `backup:DeleteRecoveryPoint` is what `drill-cleanup` needs to remove the drill's recovery point, and the deny applies whether or not the vault is locked. If the SCP was attached first, `drill-cleanup` still removes the scratch volume and the local recovery point; the one it cannot touch carries a one-day retention (`DRILL_RETENTION_DAYS` in `scripts/restore.sh`) and expires on its own. Re-run `drill-cleanup` later against the same manifest and it retries only what is outstanding.

The vault policy stops the workload account from deleting copies. SCPs on the backup account stop everyone else; set them once from the Organizations management account. Put the backup account in its own OU, not the workload account's, and deny on that OU:

| Action | Closes |
|---|---|
| `backup:DeleteBackupVault` | deleting the vault outright |
| `backup:DeleteRecoveryPoint` | deleting individual copies |
| `backup:DeleteBackupVaultLockConfiguration` | unlocking the vault, then deleting |
| `backup:UpdateRecoveryPointLifecycle` | shortening retention to expire copies early |
| `kms:ScheduleKeyDeletion`, `kms:DisableKey` | crypto-shredding the vault's key |

The last two are easy to miss, and without them the first two are theatre. Also confirm a `DenyLeaveOrganization` SCP covers the backup account; a destination account that leaves the organization keeps the backups.

Do not deny `s3:PutLifecycleConfiguration` on that OU; it breaks step 2. None of this touches the copy pipeline: SCPs do not apply to service-linked roles, and the backup account's `AWSServiceRoleForBackup` runs the copy. Keep the source account's OU free of these denies, since it needs `backup:CopyFromBackupVault` and `CopyIntoBackupVault`.

### Lock the vault

Once `drill` passes and `drill-cleanup` has removed what it created, set `vault_lock` on the module in `<backup-root>`:

```hcl
vault_lock = {
  mode               = "governance"
  min_retention_days = 7
  max_retention_days = 365
}
```

```sh
AWS_PROFILE=<backup-account-admin> terraform -chdir=<backup-root> apply
```

Governance mode, not compliance: with the OU's SCP denying `DeleteBackupVaultLockConfiguration` to every principal in the backup account, including its own admin, the lock cannot be removed from inside that account. Reversing it takes detaching the SCP from the management account first. That combination gives compliance-grade protection without compliance mode's irreversibility. Setting `vault_lock.mode` back to `"none"` fails with AccessDenied until the SCP is detached; that is expected.

## Appendix: migrating from `local` or `cross_region`

A deployment that started on `local` or `cross_region` needs one extra step between steps 4 and 5: re-keying the volume off the default `aws/ebs` key. Skip it if `aws ec2 describe-volumes` already shows `KeyManager: CUSTOMER` for the volume.

The `aws/ebs` key's policy is immutable and cannot be shared across accounts, so AWS will not copy a snapshot the destination cannot decrypt. There is no re-key-in-place API and the volume is `prevent_destroy`, so the volume is replaced out-of-band rather than by an ordinary apply.

Set `backup.mode = "cross_account"` (step 4) and apply just the key before touching the volume; a full plan errors on the volume otherwise, which is `prevent_destroy` working:

```sh
export AWS_PROFILE=<workload-account-admin>
terraform -chdir=<root> apply -target=module.thelounge.module.storage.module.data_volume.aws_kms_key.data
```

Adjust the `module.thelounge` prefix to the name your root gives the module. Then snapshot, re-encrypt, restore, and adopt:

```sh
scripts/azmove.sh --root <root> rekey
# defaults to alias/thelounge-data, the key the targeted apply created
scripts/azmove.sh --root <root> adopt <new-vol-id> <same-az>
```

Review the plan by hand before applying. The data volume must be a no-op; if it shows destroy or replace, the adopt did not take. `azmove.sh adopt` wrote a state backup to `azmove-state-<ts>.json`; `terraform state push` restores it.

```sh
terraform -chdir=<root> plan
```

Everything else in the plan should be the cross-account wiring: the volume adopting the new key, the cross-account key and vault policy statements, and the added copy action. Coming from `cross_region`, the plan also wants to destroy the replica vault, which `prevent_destroy` refuses; the next section is the deliberate way through.

Apply, then bring the site up. Apply must precede scale-up because the attach policy is scoped to the volume ARN.

```sh
terraform -chdir=<root> apply
scripts/azmove.sh --root <root> finish https://<your-chat-hostname>/
```

The old volume is untouched and is your rollback. Continue at step 5.

### Retiring the `cross_region` replica

Switching `backup.mode` away from `cross_region` drops the replica vault to count 0, but `prevent_destroy` makes the plan error instead of silently destroying the off-site copy. Retire it in two deliberate steps:

1. Empty it: delete the replica vault's recovery points by hand (`aws backup list-recovery-points-by-backup-vault` and `delete-recovery-point`, targeting the replica vault).
2. Drop the resource. keel declares the vault with `prevent_destroy`, which this repository cannot edit, so add a `removed` block for `module.thelounge.module.storage.module.data_volume.aws_backup_vault.replica[0]` (with `lifecycle { destroy = false }` to leave the vault in place, or without it once the vault is empty) and apply.

Confirm you are touching the replica key and vault, not the backup account's own; they are different resources in different accounts.

## Further notes

There is no way to skip the local copy. A copy action copies from a local recovery point, so AWS Backup cannot write straight to another account. `backup.retention_days` (local) and `backup.remote_retention_days` (copies) are tunable independently, and the local copy stays your fast restore path. Restoring, including why copying back is much slower than copying out, is [restore.md](restore.md).
