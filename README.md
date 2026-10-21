# Bash + AWS CLI EBS backups

`ebs_backup.sh` backs up EBS volumes attached to **running EC2 instances with
the exact instance tag `Backup=true`**. It applies a default 30-day retention
policy to snapshots managed by this script. It operates in one AWS account and
scans all enabled Regions by default; repeat `--region` to restrict scope.

## Requirements

- Bash 4.4+, AWS CLI v2, jq 1.6+, and authenticated AWS credentials.
- Linux, WSL, or another environment supplying those tools. macOS's built-in
  Bash 3.2 is too old; install a newer Bash if using macOS.
- The EC2 instances, rather than their volumes, must have `Backup=true`.
- The AWS identity must have `ec2:DescribeRegions`, `ec2:DescribeInstances`,
  `ec2:CreateSnapshot`, `ec2:CreateTags`, `ec2:DescribeSnapshots`, and
  `ec2:DeleteSnapshot` permissions. Encrypted snapshots also require appropriate
  KMS key access. SCPs and KMS policies still apply.

## Options

| Option | Meaning |
| --- | --- |
| `--apply` | Create and delete for real. Without it, every action is only logged as `PREVIEW` |
| `--region R` | Limit the run to Region `R`; repeat it for several. Default: all Regions enabled in the account |
| `--home-region R` | Region used to identify the account and list Regions. Default `AWS_REGION`, then `AWS_DEFAULT_REGION`, then `us-east-1` |
| `--retention-days N` | Age after which this script's snapshots are deleted, 1-99999. Default 30 |
| `--profile NAME` | AWS CLI profile to use. Without it, the default credential chain is used |
| `-h`, `--help` | Print usage |

## How the script works

**Setup.** The script stops on any error, unset variable or failed pipe
(`set -Eeuo pipefail`). It turns off the AWS CLI pager and prompts, and sets
AWS CLI retries to `standard` mode with up to 8 attempts, unless
`AWS_RETRY_MODE` or `AWS_MAX_ATTEMPTS` are already set. It checks for Bash
4.4+, AWS CLI v2 and `jq`, validates the options, then records:

- the account ID, from `sts get-caller-identity`;
- the cutoff time, which is now minus the retention days;
- a run ID made of the UTC time and the process ID, for example
  `20261021T114700Z-4242`.

**Each Region is then handled in turn:**

1. **Find the disks.** `describe-instances` lists running instances whose
   `Backup` tag is exactly `true`; `True` or `yes` do not match. Every attached
   EBS volume is collected. A Multi-Attach volume shared by several selected
   instances is snapshotted once.
2. **Snapshot them** (apply only). `create-snapshot` runs once per volume, with
   these tags set in the same call:

   | Tag | Value |
   | --- | --- |
   | `ManagedBy` | `ebs-backup-cli` |
   | `BackupPolicy` | `running-Backup-true-v1` |
   | `CreatedByAccount` | the account ID |
   | `SourceVolume`, `SourceInstance` | the volume, and one instance it is attached to |
   | `RunId` | the run ID |

   The first three are how the script later recognises its own snapshots.
3. **Wait for them to finish.** A requested snapshot is not a finished one, so
   the script waits for each new snapshot to complete, one at a time. If any
   snapshot in the Region failed to start or was not confirmed, nothing is
   deleted in that Region during this run.
4. **Find expired snapshots.** `describe-snapshots` lists this account's
   completed snapshots that carry the three ownership tags. A jq filter keeps
   only those that meet all of these conditions:
   - owned by this account, completed, and in the standard tier;
   - carrying the three tags with the exact expected values;
   - with no `Keep` or `DoNotDelete` tag, in any capitalisation;
   - started before the cutoff.
5. **Delete them** (apply only). Immediately before each deletion the snapshot
   is read again and put through the same filter, so a `Keep` tag added
   meanwhile still protects it. AWS can still refuse a deletion; that is
   logged and counted as a failure.

**Finish.** A summary line reports backup candidates, snapshots created,
expired candidates, snapshots deleted and failures. The exit code is 1 if
anything failed. Temporary files are removed on exit, even after an error.

Every log line goes to stderr, prefixed with a UTC timestamp, for example:

```text
2026-10-21T11:47:00Z PREVIEW create snapshot region=us-east-1 instance=i-0abc volume=vol-0def
2026-10-21T11:47:02Z SUMMARY backup_candidates=1 created=0 expired_candidates=0 deleted=0 failures=0 apply=false
```

### Safety design

- Preview is the default; `--apply` must be given to change anything.
- It only deletes snapshots carrying all three of its ownership tags.
- A `Keep` or `DoNotDelete` tag protects a snapshot.
- Nothing in a Region is deleted unless every new backup there was confirmed.
- Each snapshot is checked again right before it is deleted.
- The included IAM policy enforces the same tags on the AWS side.

### Limits at a glance

These are explained further under [Behavior and retention scope](#behavior-and-retention-scope)
and [Operational notes](#operational-notes).

- **Only running instances are backed up.** A stopped instance with
  `Backup=true` is skipped.
- **Backups are crash-consistent**, like pulling the power. Open files and
  databases are not flushed first. An instance's volumes are snapshotted
  separately, moments apart, not as one consistent set.
- **There is no "keep at least one" rule.** If an instance loses its tag or is
  terminated, its last snapshots are still deleted once they pass the
  retention age.
- **The wait gives up after about 10 minutes.** A volume's first snapshot, or a
  very large one, can take longer. That counts as a failure and skips retention
  in that Region for the run.
- **Regions are processed one after another**, so a run over many Regions with
  large volumes can take a long time.

## Preview (default, no changes)

```bash
bash ebs_backup.sh --profile production --region us-east-1
```

The preview lists volumes that would be backed up and existing expired managed
snapshots that would be deleted. Preview does not validate write permissions or
prove that future snapshots will complete; an apply run may skip retention on
backup failures.

## Create backups and enforce retention

```bash
bash ebs_backup.sh --profile production --region us-east-1 --apply
```

All enabled Regions:

```bash
bash ebs_backup.sh --profile production --apply
```

Multiple Regions and a different retention period:

```bash
bash ebs_backup.sh --profile production \
  --region us-east-1 --region us-west-2 --retention-days 45 --apply
```

Omit `--profile` to use the AWS CLI's default credential chain, such as an EC2
instance role. `--home-region` controls the initial STS/Region-discovery calls;
it defaults to AWS_REGION, AWS_DEFAULT_REGION, then us-east-1.

## Behavior and retention scope

1. Identify the current AWS account and enabled Regions.
2. Discover running instances with `Backup=true`, including all paginated results.
3. Collect every attached EBS volume, including root volumes. Ignore instance
   store disks. Deduplicate shared Multi-Attach volumes within each Region.
4. In apply mode, request one snapshot per unique volume, tagging it atomically
   with `ManagedBy=ebs-backup-cli`, `BackupPolicy=running-Backup-true-v1`,
   `CreatedByAccount`, `SourceVolume`, `SourceInstance`, and `RunId`.
5. Wait for the new snapshots to complete. Any creation failure or waiter failure
   disables retention for that entire Region during this run.
6. Delete only owned, completed, standard-tier snapshots with all three matching
   ownership/policy/account tags and a `StartTime` strictly older than 30 days.
   Snapshot age is measured from the start time, not completion time. Exactly
   30 days old is retained. Archived/pending/error snapshots are not deleted.
7. Recheck owner, tags, state, tier and age immediately before each deletion.

The retention policy continues to apply to managed snapshots even when their
original instance is stopped, terminated, or no longer tagged for backup.
A Region with zero matching live volumes still has its managed retention policy
enforced. There is no minimum-count or keep-last-snapshot exception. Volumes
and snapshots created outside this script's policy scope are untouched.

Add a `Keep` or `DoNotDelete` tag to a snapshot to exclude it from retention.
Protection checks are case insensitive for tag keys, and key presence protects
the snapshot regardless of value. Do not reuse this policy's ownership tags on
snapshots you do not want this script to manage. IAM tag conditions provide an
additional enforcement layer; an example policy is included.

Snapshots referenced by AMIs or protected by AWS controls may reject deletion.
The script reports the error and continues; it never deregisters AMIs or removes
locks. Recycle Bin rules may retain deleted snapshots and their storage charges.

## Operational notes

- Logs and a final summary go to stderr; capture them with `2>&1 | tee backup.log`.
- Exit 0 means no detected errors; exit 1 means a failure or partial run. Check
  logs for skipped Regions and snapshots. CLI usage/dependency errors fail early.
- The AWS CLI automatically paginates JSON responses. Do not add `--no-paginate`
  or `--max-items`, which could silently restrict the inventory.
- The built-in waiter may time out after roughly ten minutes for large snapshots.
  Such snapshots may still finish later. Retention is skipped in that Region;
  inspect completion before another run. There is no automatic cancellation.
- SDK retries are configured for transient failures. Each invocation creates new
  backups; interruption and reruns can create extra snapshots. RunId tags assist
  investigation but are not an idempotency token. Avoid overlapping executions
  using your scheduler's concurrency controls or `flock` on Linux.
- Separate per-volume snapshots are not an atomic multi-volume backup. Writes
  cached in memory may not be captured. Use application quiescing or an appropriate
  multi-volume/application-consistent backup workflow for database consistency.
- Inventory can change while scanning. A volume detached after discovery can
  still be snapshotted if it remains accessible to this account.
- No AWS resources were modified while building or testing this script.

## IAM example

`iam-policy.json` is a starting point for a commercial AWS account. It allows
discovery and snapshot creation, requires ownership tags on new snapshots, and
restricts DeleteSnapshot to this policy's matching snapshot resource tags.
Adapt partitions, Regions, account boundaries, volume scope, KMS permissions,
and organizational requirements before attaching it to a role. It does not
grant IAM or KMS administration permissions.

### What each statement allows

`${aws:PrincipalAccount}` is filled in by AWS with the account of whoever is
using the policy, so the file needs no account ID and works unchanged in any
account. `*` in the Region position means every Region.

| Statement (`Sid`) | Actions | On | Condition | Why the script needs it |
| --- | --- | --- | --- | --- |
| `Discovery` | `DescribeRegions`, `DescribeInstances`, `DescribeSnapshots` | everything (`*`) | none | Listing Regions, tagged instances and snapshots, and the wait for completion. These read-only calls cannot be limited to particular resources |
| `SnapshotVolumeAccess` | `CreateSnapshot` | any volume in this account | none | Taking a snapshot is checked against the volume being copied |
| `TaggedSnapshotCreation` | `CreateSnapshot` | any new snapshot | the request must set `ManagedBy=ebs-backup-cli`, `BackupPolicy=running-Backup-true-v1` and `CreatedByAccount=<this account>` | A snapshot cannot be created without the ownership tags |
| `TagDuringCreationOnly` | `CreateTags` | snapshots | only as part of `CreateSnapshot` | Applying the tags in the same call. The role cannot tag a snapshot afterwards |
| `DeleteOnlyManagedSnapshots` | `DeleteSnapshot` | snapshots | the snapshot must already carry the same three tags and values | Retention can only delete this script's own snapshots |

`CreateSnapshot` appears twice because AWS checks it against two resources:
the volume being read and the snapshot being created. Both statements must
allow the request.

### What this guarantees, and what it does not

The tag conditions repeat the script's own safety rules on the AWS side, so
they hold even if the script has a bug or someone runs other commands with the
same role:

- Every snapshot the role creates carries the ownership tags.
- The role cannot delete any other snapshot, such as one made by hand or by AWS
  Backup.
- The role cannot add the ownership tags to an existing snapshot to make it
  deletable, because tagging is only allowed while creating.

The policy does **not** enforce these; they rely on the script:

- **Age.** The role may delete a managed snapshot of any age. The retention
  cutoff is applied by the script.
- **`Keep` and `DoNotDelete` tags.** The role may delete a managed snapshot
  that carries them. To enforce that in IAM too, add a `Deny` statement on
  `ec2:DeleteSnapshot` with a `Null` condition on `ec2:ResourceTag/Keep` and
  `ec2:ResourceTag/DoNotDelete`.
- **Other principals.** Anyone else allowed `ec2:CreateTags` on snapshots could
  add the ownership tags to a snapshot and so make it deletable by this role.
  Restrict who may set those tag keys if that matters.

Further points:

- **Encrypted volumes.** The policy grants no KMS permissions. Volumes
  encrypted with the default `aws/ebs` key work as they are. For a
  customer-managed key, check its key policy: if it limits which roles may use
  it, this role may need to be added. Test one snapshot before relying on it.
- **No STS permission is needed.** `sts:GetCallerIdentity`, which the script
  uses to find the account, is always allowed.
- **Other partitions.** The ARNs start with `arn:aws:`. For GovCloud or China
  Regions, change them to `arn:aws-us-gov:` or `arn:aws-cn:`.
- **Narrowing it further.** Replace `*` in the Region position with specific
  Regions, or add a condition such as `aws:RequestedRegion`, to limit where the
  role works.

### Attaching it

Create a role, or use an existing one, for wherever the script runs: an EC2
instance profile, a scheduled ECS/Lambda task, or a CI role. Then attach the
policy, for example inline:

```bash
aws iam put-role-policy \
  --role-name ebs-backup \
  --policy-name EbsBackupCli \
  --policy-document file://iam-policy.json
```

Service control policies, permissions boundaries and KMS key policies can still
deny actions this policy allows.

## Tests

`test_backup.py` checks the script's behaviour without touching AWS. It runs
the real `ebs_backup.sh`, but puts a fake `aws` command first on the `PATH`.
The fake answers each AWS CLI call with fixed data and writes every call it
receives to a log, so a test can check exactly what the script asked AWS to do,
and in what order.

### Running them

```bash
python3 -m unittest -v test_backup
```

They need the same tools as the script: Bash 4.4+, jq, and Python 3 as
`python3`. The AWS CLI is not needed, and no credentials are used. Run them on
Linux, macOS with a newer Bash, or in WSL. On plain Windows they fail: `bash`
may resolve to a different shell, and Windows builds of jq 1.6 cannot parse
dates (`strptime/1 not implemented on this platform`).

### The fake AWS account

The fake reports account `111111111111` with one Region, `us-east-1`, and these
instances, all running and tagged `Backup=true`:

| Instance | Volumes |
| --- | --- |
| `i-first` | `vol-root`, `vol-shared` |
| `i-second` | `vol-shared` (the same volume, Multi-Attach) |

It also has six snapshots carrying the script's three ownership tags. Only one
of them should ever be deleted:

| Snapshot | Why it is or is not eligible |
| --- | --- |
| `snap-expired` | 31 days old: **deleted** |
| `snap-fresh` | 2 days old: kept, too new |
| `snap-kept` | Has a `KEEP` tag (upper case, value `false`): kept, since any `Keep` key protects it |
| `snap-other-account` | Owned by account `222222222222`: kept |
| `snap-archive` | In the archive tier: kept |
| `snap-pending` | Not completed: kept |

The environment variable `SCENARIO` makes the fake fail at a chosen point, so
the error paths can be tested.

### What each test proves

| Test | Scenario | Expected result |
| --- | --- | --- |
| `test_preview_does_not_mutate` | Preview, normal | No create, wait or delete calls. Reports 2 backup candidates and 1 expired snapshot. Exit 0 |
| `test_apply_deduplicates_waits_tags_and_deletes` | Apply, normal | 2 snapshots for 3 attachments (the shared volume once), 2 waits, then 1 deletion of `snap-expired`, after every wait. New snapshots carry `ManagedBy=ebs-backup-cli`. Instances are filtered on running and `Backup=true`. Exit 0 |
| `test_creation_failure_blocks_retention` | Creating a snapshot fails | Snapshots are not even listed for retention. Exit 1 |
| `test_wait_failure_blocks_retention` | Waiting for a snapshot fails | No deletion. Exit 1 |
| `test_tag_recheck_prevents_deletion` | `DoNotDelete` is added between listing and deleting | The re-check before deleting catches it; no deletion. Exit 0 |
| `test_delete_failure_is_nonzero` | AWS refuses the deletion | Logs `deletion rejected`. Exit 1 |
| `test_discovery_failure_does_not_prune` | Listing instances fails | The Region is skipped; no deletion. Exit 1 |
| `test_no_current_volumes_still_applies_retention` | No tagged instances | Nothing is created, and `snap-expired` is still deleted. Exit 0 |
| `test_exact_cutoff_and_utc_timestamp_formats` | Runs the script's own jq filter on three snapshots around a fixed cutoff | Only the one older than the cutoff matches. A snapshot exactly at the cutoff is kept. Both `+00:00` and `Z` time formats, with or without fractions of a second, are read |

### What they do not cover

They prove the script's logic, not AWS itself. The fake accepts every request,
so these are not tested:

- IAM permissions and `iam-policy.json`;
- real snapshot timing, including the 10-minute wait limit;
- AWS paging through large result sets;
- several Regions in one run;
- AWS refusing deletions for its own reasons, such as AMIs or snapshot locks.

Try a preview, and then one apply against a test instance, before scheduling
the script.

## AWS references

- [DescribeInstances filters](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html)
- [CreateSnapshot and tag specifications](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-snapshot.html)
- [SnapshotCompleted waiter](https://docs.aws.amazon.com/cli/latest/reference/ec2/wait/snapshot-completed.html)
- [DescribeSnapshots](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-snapshots.html)
- [DeleteSnapshot](https://docs.aws.amazon.com/cli/latest/reference/ec2/delete-snapshot.html)
