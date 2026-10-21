"""Offline integration tests. AWS CLI is replaced with a local fixture executable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
FAKE_AWS = r'''#!/usr/bin/env python3
import datetime, json, os, sys
args = sys.argv[1:]
if args == ['--version']:
    print('aws-cli/2.38.1 Python/3'); sys.exit(0)
with open(os.environ['FAKE_LOG'], 'a') as f:
    f.write(json.dumps(args) + '\n')
if 'get-caller-identity' in args:
    print(json.dumps({'Account': '111111111111'}))
elif 'describe-regions' in args:
    print(json.dumps({'Regions': [{'RegionName': 'us-east-1'}]}))
elif 'describe-instances' in args:
    if os.environ.get('SCENARIO') == 'discovery-failure': sys.exit(1)
    vols = [] if os.environ.get('SCENARIO') == 'no-volumes' else [
        {'InstanceId': 'i-first', 'BlockDeviceMappings': [
            {'Ebs': {'VolumeId': 'vol-root'}}, {'Ebs': {'VolumeId': 'vol-shared'}}]},
        {'InstanceId': 'i-second', 'BlockDeviceMappings': [{'Ebs': {'VolumeId': 'vol-shared'}}]}]
    print(json.dumps({'Reservations': [{'Instances': vols}]}))
elif 'create-snapshot' in args:
    if os.environ.get('SCENARIO') == 'create-failure': sys.exit(1)
    volume = args[args.index('--volume-id')+1]
    print(json.dumps({'SnapshotId': 'snap-new-' + volume}))
elif 'wait' in args:
    if os.environ.get('SCENARIO') == 'wait-failure': sys.exit(255)
elif 'describe-snapshots' in args:
    now = datetime.datetime.now(datetime.timezone.utc)
    tags = [{'Key': k, 'Value': v} for k,v in {
        'ManagedBy': 'ebs-backup-cli', 'BackupPolicy': 'running-Backup-true-v1',
        'CreatedByAccount': '111111111111'}.items()]
    def snap(id, age=31, extra=None, owner='111111111111', state='completed', tier='standard'):
        return {'SnapshotId': id, 'StartTime': (now-datetime.timedelta(days=age)).isoformat(),
                'Tags': tags + (extra or []), 'OwnerId': owner, 'State': state, 'StorageTier': tier}
    snapshots = [snap('snap-expired'), snap('snap-fresh', age=2),
                 snap('snap-kept', extra=[{'Key':'KEEP','Value':'false'}]),
                 snap('snap-other-account', owner='222222222222'),
                 snap('snap-archive', tier='archive'), snap('snap-pending', state='pending')]
    if '--snapshot-ids' in args:
        snapshots = [s for s in snapshots if s['SnapshotId'] == args[args.index('--snapshot-ids')+1]]
        if os.environ.get('SCENARIO') == 'new-protection':
            snapshots[0]['Tags'].append({'Key': 'DoNotDelete', 'Value': 'true'})
    print(json.dumps({'Snapshots': snapshots}))
elif 'delete-snapshot' in args:
    if os.environ.get('SCENARIO') == 'delete-failure': sys.exit(1)
else:
    print('Unexpected fake AWS call', args, file=sys.stderr); sys.exit(1)
'''


class BackupTests(unittest.TestCase):
    def run_script(self, apply=False, scenario='normal'):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            fake = folder / 'aws'
            fake.write_text(FAKE_AWS)
            fake.chmod(0o755)
            env = {**os.environ, 'PATH': str(folder) + os.pathsep + os.environ['PATH'],
                   'FAKE_LOG': str(folder / 'calls.jsonl'), 'SCENARIO': scenario}
            cmd = ['bash', str(ROOT / 'ebs_backup.sh'), '--profile', 'test']
            if apply:
                cmd.append('--apply')
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (folder / 'calls.jsonl').read_text().splitlines()]
            return result, calls

    def test_preview_does_not_mutate(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('create-snapshot' in c or 'delete-snapshot' in c or 'wait' in c for c in calls))
        self.assertIn('backup_candidates=2', result.stderr)
        self.assertIn('expired_candidates=1', result.stderr)

    def test_apply_deduplicates_waits_tags_and_deletes(self):
        result, calls = self.run_script(apply=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        creates = [c for c in calls if 'create-snapshot' in c]
        self.assertEqual(len(creates), 2)
        self.assertEqual(len([c for c in calls if 'wait' in c]), 2)
        deletes = [c for c in calls if 'delete-snapshot' in c]
        self.assertEqual(len(deletes), 1)
        self.assertIn('snap-expired', deletes[0])
        self.assertLess(max(i for i,c in enumerate(calls) if 'wait' in c),
                        next(i for i,c in enumerate(calls) if 'delete-snapshot' in c))
        tags = json.loads(creates[0][creates[0].index('--tag-specifications')+1])[0]['Tags']
        self.assertIn({'Key':'ManagedBy','Value':'ebs-backup-cli'}, tags)
        discover = next(c for c in calls if 'describe-instances' in c)
        self.assertIn('Name=instance-state-name,Values=running', discover)
        self.assertIn('Name=tag:Backup,Values=true', discover)

    def test_creation_failure_blocks_retention(self):
        result, calls = self.run_script(apply=True, scenario='create-failure')
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any('delete-snapshot' in c or 'describe-snapshots' in c for c in calls))

    def test_wait_failure_blocks_retention(self):
        result, calls = self.run_script(apply=True, scenario='wait-failure')
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any('delete-snapshot' in c for c in calls))

    def test_tag_recheck_prevents_deletion(self):
        result, calls = self.run_script(apply=True, scenario='new-protection')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('delete-snapshot' in c for c in calls))

    def test_delete_failure_is_nonzero(self):
        result, calls = self.run_script(apply=True, scenario='delete-failure')
        self.assertEqual(result.returncode, 1)
        self.assertIn('deletion rejected', result.stderr)

    def test_discovery_failure_does_not_prune(self):
        result, calls = self.run_script(apply=True, scenario='discovery-failure')
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any('delete-snapshot' in c for c in calls))

    def test_no_current_volumes_still_applies_retention(self):
        result, calls = self.run_script(apply=True, scenario='no-volumes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('create-snapshot' in c for c in calls))
        self.assertEqual(len([c for c in calls if 'delete-snapshot' in c]), 1)

    def test_exact_cutoff_and_utc_timestamp_formats(self):
        source = (ROOT / 'ebs_backup.sh').read_text()
        program = source.split("<<'JQ'\n", 1)[1].split('\nJQ', 1)[0]
        base = {'OwnerId': '111111111111', 'State': 'completed', 'Tags': [
            {'Key':'ManagedBy','Value':'ebs-backup-cli'},
            {'Key':'BackupPolicy','Value':'running-Backup-true-v1'},
            {'Key':'CreatedByAccount','Value':'111111111111'}]}
        snapshots = [{**base, 'SnapshotId': 'old', 'StartTime': '2026-01-01T00:00:00.000+00:00'},
                     {**base, 'SnapshotId': 'equal', 'StartTime': '2026-01-02T00:00:00Z'},
                     {**base, 'SnapshotId': 'new', 'StartTime': '2026-01-03T00:00:00Z'}]
        result = subprocess.run(['jq','-r','--arg','account','111111111111',
            '--arg','manager','ebs-backup-cli','--arg','policy','running-Backup-true-v1',
            '--argjson','cutoff','1767312000',program],
            input=json.dumps({'Snapshots': snapshots}), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'old')


if __name__ == '__main__':
    unittest.main()
