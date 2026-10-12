"""Merge the selected research model into a complete live rig with an audited change list."""
import argparse
import copy
import datetime
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
OUTPUT = ROOT / 'output/live-research-port'


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def merge(document, profile, registry, factory, name):
    """Change only named prototype parameters; all other rig state is copied exactly."""
    if document.get('version') != 2 or 'snapshot' not in document:
        raise ValueError('Capture a complete version-2 preset with the current Release app first.')
    original = document['snapshot']
    rows = original['instrument']['strings']
    if not all('set' in row and 'followsScale' in row for row in rows):
        raise ValueError('The source preset is missing string-bank or pitch-source tags.')
    values = original['paramValues']
    if set(values) != set(registry):
        raise ValueError('The source preset must contain every current registry parameter.')
    changes = dict(profile['source_parameters'])
    for key in changes:
        if key.startswith('bow_jt') or registry[key]['apply'] != 'rebuild':
            raise ValueError('Not a prototype source scalar: ' + key)
    changes.update(profile['observation_parameters'])
    # Match the reference body's absolute frequencies while retaining the player's tonic.
    changes['bow_body_air_ratio'] = (factory['bow_body_air_ratio']
        * profile['reference_tonic_hz'] / original['instrument']['tonicHz'])
    for key in changes:
        if (key not in registry or key.startswith(('bow_jt', 'ctl_', 'tp_', 'st_', 'fx_'))
                or registry[key]['apply'] == 'hybrid'):
            raise ValueError('Protected or unsupported parameter in the research profile: ' + key)
    result = copy.deepcopy(document)
    body = result['snapshot']
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
    for target in (result, body):
        target.update(name=name, savedAt=stamp, savedBy='Tarabdaar research merge: ' + profile['selected_model'])
    body['paramValues'].update(changes)
    untouched_sections = set(original) - {'name', 'savedAt', 'savedBy', 'paramValues'}
    assert all(body[k] == original[k] for k in untouched_sections)
    assert all(body['paramValues'][k] == v for k, v in values.items() if k not in changes)
    audit = dict(selected_model=profile['selected_model'],
        changed_parameters={k: {'before': values[k], 'after': v}
                            for k, v in changes.items() if v != values[k]},
        preserved_sections=sorted(untouched_sections),
        preserved_parameter_count=len(values.keys() - changes.keys()),
        bank_counts={bank: {'total': sum(r['set'] == bank for r in rows),
                           'enabled': sum(r['set'] == bank and r['enabled'] for r in rows)}
                     for bank in ('raga', 'chromatic')},
        all_nonprototype_settings_exact=True)
    return result, audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=pathlib.Path, required=True)
    parser.add_argument('--name', default='Research sarangi - preserved live rig')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    profile = read(HERE / 'profile.json')
    factory_path = ROOT / 'Packages/SarangiKit/Sources/SarangiKit/Resources/bowed_string.json'
    if digest(factory_path) != profile['source_artifact_sha256']:
        raise ValueError('The prototype source artifact changed; requalify the profile before importing.')
    if digest(ROOT / profile['source_job']) != profile['source_job_sha256']:
        raise ValueError('The frozen prototype job changed.')
    manifest = read(HERE / 'manifest.json')
    for path, expected in manifest['assets'].items():
        if digest(ROOT / path) != expected:
            raise ValueError('The fitted observation asset changed: ' + path)
    rows = json.loads(subprocess.check_output([
        'swift', 'run', '-c', 'release', '--package-path', str(ROOT / 'Packages/TarabdaarCore'),
        'paramdoc', '--json'], text=True))
    registry = {row['key']: row for row in rows}
    result, audit = merge(read(args.base), profile, registry, read(factory_path), args.name)
    audit.update(base_path=str(args.base.resolve()), base_sha256=digest(args.base),
                 profile_sha256=digest(HERE / 'profile.json'))
    destination = args.output or OUTPUT / (args.name + '.tarabdaar')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    audit['preset_sha256'] = digest(destination)
    destination.with_suffix('.audit.json').write_text(json.dumps(audit, indent=2, sort_keys=True) + '\n')
    print('Saved', destination)
    print(len(audit['changed_parameters']), 'prototype parameter changes;',
          audit['preserved_parameter_count'], 'other parameters and every non-parameter section preserved.')


if __name__ == '__main__':
    main()
