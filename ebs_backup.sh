#!/usr/bin/env bash
# Snapshot EBS volumes of running instances tagged Backup=true.
# Default is preview. Use --apply to create snapshots and enforce retention.
set -Eeuo pipefail
export AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-8}"

usage() {
  cat <<'EOF'
Usage: bash ebs_backup.sh [--apply] [--profile NAME] [--region REGION ...]
                         [--home-region REGION] [--retention-days DAYS]

Default: preview across all enabled Regions in the current AWS account.
--region can be repeated. --apply enables creation and retention deletion.
Requires Bash 4.4+, AWS CLI v2, and jq 1.6+. Instance tag matching is exact.
EOF
}
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "Bash 4.4 or newer required"
apply=false
profile=""
home_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
retention_days=30
regions=()
while (($#)); do
  case "$1" in
    --apply) apply=true; shift ;;
    --profile|--region|--home-region|--retention-days)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --profile) profile=$2 ;;
        --region) regions+=("$2") ;;
        --home-region) home_region=$2 ;;
        --retention-days) retention_days=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ $retention_days =~ ^[1-9][0-9]{0,4}$ ]] || die "Retention must be 1..99999 days"
for cmd in aws jq; do command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"; done
[[ $(aws --version 2>&1) == aws-cli/2.* ]] || die "AWS CLI v2 required"

aws_base=(aws)
[[ -z $profile ]] || aws_base+=(--profile "$profile")
aws_json() { "${aws_base[@]}" "$@" --output json; }
managed_by="ebs-backup-cli"
policy="running-Backup-true-v1"
cutoff_epoch=$(jq -n --argjson days "$retention_days" 'now | floor | . - ($days * 86400)')
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
account=$(aws_json --region "$home_region" sts get-caller-identity | jq -er '.Account')

if ((${#regions[@]} == 0)); then
  region_json=$(aws_json --region "$home_region" ec2 describe-regions)
  mapfile -t regions < <(jq -r '.Regions[].RegionName' <<<"$region_json" | sort -u)
fi
((${#regions[@]})) || die "No Regions found"
# Deduplicate explicitly repeated --region arguments.
mapfile -t regions < <(printf '%s\n' "${regions[@]}" | sort -u)
log "Account=$account run=$run_id apply=$apply retention_days=$retention_days"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
failures=0
created=0
deleted=0
planned_backups=0
planned_deletions=0

# jq program shared by discovery and the immediate pre-delete recheck.
# Only this account's completed standard-tier snapshots with our exact tags.
cat >"$tmp/eligible.jq" <<'JQ'
def tags: reduce (.Tags // [])[] as $t ({}; .[$t.Key] = $t.Value);
def epoch:
  sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
.Snapshots[]
| . as $s | (tags) as $t
| select(.OwnerId == $account and .State == "completed")
| select((.StorageTier // "standard") == "standard")
| select($t.ManagedBy == $manager and $t.BackupPolicy == $policy
         and $t.CreatedByAccount == $account)
| select(($t | keys | map(ascii_downcase) | index("donotdelete")) == null)
| select(($t | keys | map(ascii_downcase) | index("keep")) == null)
| select((.StartTime | epoch) < $cutoff)
| .SnapshotId
JQ
eligible_ids() {
  jq -r --arg account "$account" --arg manager "$managed_by" --arg policy "$policy" \
    --argjson cutoff "$cutoff_epoch" -f "$tmp/eligible.jq"
}

for region in "${regions[@]}"; do
  log "Scanning Region=$region"
  region_failed=false
  new_snapshots=()
  # AWS CLI automatically paginates JSON results; do not use --no-paginate.
  if ! instances=$(aws_json --region "$region" ec2 describe-instances --filters \
      'Name=instance-state-name,Values=running' 'Name=tag:Backup,Values=true'); then
    log "ERROR: instance discovery failed in $region; skipping this Region"
    failures=$((failures + 1)); continue
  fi
  # Dedupe Multi-Attach volumes shared by multiple selected instances.
  # A SourceInstance tag records one of the matching instances for attribution.
  if ! jq -r '[.Reservations[].Instances[]
      | .InstanceId as $instance | .BlockDeviceMappings[]?
      | select(.Ebs.VolumeId != null) | {volume: .Ebs.VolumeId, instance: $instance}]
      | unique_by(.volume)[] | [.volume, .instance] | @tsv' \
      <<<"$instances" >"$tmp/volumes.tsv"; then
    log "ERROR: invalid instance inventory in $region"
    failures=$((failures + 1)); continue
  fi
  while IFS=$'\t' read -r volume instance; do
    [[ -n $volume ]] || continue
    planned_backups=$((planned_backups + 1))
    if ! $apply; then
      log "PREVIEW create snapshot region=$region instance=$instance volume=$volume"
      continue
    fi
    tags=$(jq -cn --arg manager "$managed_by" --arg policy "$policy" \
      --arg account "$account" --arg volume "$volume" --arg instance "$instance" \
      --arg run "$run_id" '[{ResourceType:"snapshot", Tags:[
        {Key:"ManagedBy",Value:$manager}, {Key:"BackupPolicy",Value:$policy},
        {Key:"CreatedByAccount",Value:$account}, {Key:"SourceVolume",Value:$volume},
        {Key:"SourceInstance",Value:$instance}, {Key:"RunId",Value:$run}]}]')
    if response=$(aws_json --region "$region" ec2 create-snapshot \
        --volume-id "$volume" --description "Scheduled EBS backup $run_id $instance $volume" \
        --tag-specifications "$tags") && snapshot=$(jq -er '.SnapshotId' <<<"$response"); then
      log "CREATED region=$region volume=$volume snapshot=$snapshot"
      new_snapshots+=("$snapshot")
      created=$((created + 1))
    else
      log "ERROR: snapshot creation failed region=$region volume=$volume"
      failures=$((failures + 1)); region_failed=true
    fi
  done <"$tmp/volumes.tsv"

  # Completion, not just successful request submission, gates retention.
  # Wait one ID at a time to avoid API argument limits on large fleets.
  for snapshot in "${new_snapshots[@]}"; do
    log "WAIT region=$region snapshot=$snapshot"
    if ! "${aws_base[@]}" --region "$region" ec2 wait snapshot-completed --snapshot-ids "$snapshot"; then
      log "ERROR: snapshot failed or waiter timed out; retention disabled in $region"
      failures=$((failures + 1)); region_failed=true
    fi
  done
  if $region_failed; then
    log "SKIP retention in $region because at least one backup is unconfirmed"
    continue
  fi

  if ! snapshots=$(aws_json --region "$region" ec2 describe-snapshots --owner-ids "$account" \
      --filters "Name=tag:ManagedBy,Values=$managed_by" "Name=tag:BackupPolicy,Values=$policy" \
                "Name=tag:CreatedByAccount,Values=$account" 'Name=status,Values=completed'); then
    log "ERROR: snapshot discovery failed region=$region"
    failures=$((failures + 1)); continue
  fi
  if ! eligible_ids <<<"$snapshots" >"$tmp/expired.txt"; then
    log "ERROR: snapshot dates or metadata invalid; retention skipped in $region"
    failures=$((failures + 1)); continue
  fi
  while IFS= read -r snapshot; do
    [[ -n $snapshot ]] || continue
    planned_deletions=$((planned_deletions + 1))
    if ! $apply; then
      log "PREVIEW delete expired snapshot region=$region snapshot=$snapshot"
      continue
    fi
    # Recheck tags, owner, state and age immediately before requesting deletion.
    if ! current=$(aws_json --region "$region" ec2 describe-snapshots --snapshot-ids "$snapshot"); then
      log "ERROR: unable to recheck snapshot=$snapshot"
      failures=$((failures + 1)); continue
    fi
    if ! eligible=$(eligible_ids <<<"$current"); then
      log "ERROR: malformed snapshot metadata snapshot=$snapshot"
      failures=$((failures + 1)); continue
    fi
    if [[ $eligible != "$snapshot" ]]; then
      log "SKIP snapshot=$snapshot no longer eligible"
      continue
    fi
    if "${aws_base[@]}" --region "$region" ec2 delete-snapshot --snapshot-id "$snapshot"; then
      log "DELETED region=$region snapshot=$snapshot"
      deleted=$((deleted + 1))
    else
      # AMI dependencies, Snapshot Lock, Recycle Bin rules, IAM, etc. remain effective.
      log "ERROR: deletion rejected region=$region snapshot=$snapshot"
      failures=$((failures + 1))
    fi
  done <"$tmp/expired.txt"
done

log "SUMMARY backup_candidates=$planned_backups created=$created expired_candidates=$planned_deletions deleted=$deleted failures=$failures apply=$apply"
((failures == 0)) || exit 1
