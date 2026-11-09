"""Validate copy startup measurements before an installer stops its service."""
import hashlib
import json
import math
from pathlib import Path
import sys
import time


def measured_window(path, capture, service, preparation):
    value = json.loads(Path(path).read_text())
    manifest = json.loads((Path(capture) / 'capture-manifest.json').read_text())
    seconds = value.get('launch_to_healthy_seconds')
    if (value.get('format') != 1 or value.get('kind') != 'checklist-owned-copy-startup'
            or value.get('first_start') is not True or value.get('live_snapshot') is not True
            or type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds <= 0):
        raise ValueError('Offline qualification must contain a successful measured first startup of a live-backup copy.')
    if value.get('source_fingerprint') != manifest['source_fingerprint']:
        raise ValueError('Offline qualification names a different staged build.')
    digest = hashlib.sha256(Path(service).read_bytes()).hexdigest()
    if value.get('service_sha256') != digest:
        raise ValueError('Offline qualification names a different staged service executable.')
    if any(type(value.get(key)) is not int for key in ['source_schema', 'target_schema']):
        raise ValueError('Offline qualification schemas must be integers.')
    if value.get('target_schema') != preparation.get('target_schema'):
        raise ValueError('Offline qualification target schema differs from upgrade preparation.')
    for key in ['source_schema', 'logical_store_id', 'source_root']:
        optional_legacy_identity = key == 'logical_store_id' and value['source_schema'] == 0
        if (value.get(key) is None and not optional_legacy_identity) or value.get(key) != preparation.get(key):
            raise ValueError('Offline qualification differs from the installation: ' + key)
    measured_at = value.get('measured_at_unix')
    if type(measured_at) not in (int, float) or not math.isfinite(measured_at) or not 0 <= time.time() - measured_at <= 72 * 3600:
        raise ValueError('Offline qualification must be at most 72 hours old.')
    if preparation['needs_upgrade'] and not value['source_schema'] < value['target_schema']:
        raise ValueError('A store upgrade requires a copy measured through that schema upgrade.')
    return value


def report(preparation, capture, service, measurement=None):
    seconds = preparation.get('expected_offline_seconds')
    if (type(preparation.get('needs_upgrade')) is not bool or type(preparation.get('prepared')) is not bool
            or type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds <= 0):
        raise ValueError('Invalid store-upgrade preparation receipt; the installed app is untouched.')
    print('Store upgrade preparation: ' + json.dumps(preparation, sort_keys=True), flush=True)
    if preparation['needs_upgrade']:
        if not measurement:
            raise ValueError('A store upgrade needs --offline-measurement from the exact staged build on an owned live-backup copy; the installed app is untouched.')
        observed = measured_window(measurement, capture, service, preparation)
        # First startup includes the full protected path. Preparation can shorten
        # the actual outage; never use its online duration as an offline sample.
        measured = observed['launch_to_healthy_seconds']
        budget = math.ceil(measured * 1.25 + 10)
        print(f'Expected service offline window: about {budget:g} s; measured copy first startup {measured:.3f} s '
              f'(25% margin + 10 s; source schema {observed["source_schema"]} to {observed["target_schema"]}; '
              f'load {observed.get("load_start", "unknown")}). A changed store uses the full protected startup and reports its reason.', flush=True)
    else:
        print(f'Expected service offline window: about {seconds:g} s; no store upgrade is required (startup estimate).', flush=True)


if __name__ == '__main__':
    try:
        report(json.loads(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None)
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(str(error))
