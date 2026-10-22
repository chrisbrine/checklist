#!/usr/bin/env python3
"""Read-only checks for the prepared public planning package, not product tests."""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from urllib.parse import unquote

from jsonschema import Draft202012Validator, FormatChecker
import yaml

from public_source_privacy import private_identifiers

ROOT = Path(__file__).resolve().parents[1]


def public_files() -> set[Path]:
    files = {ROOT / p for p in ('README.md', 'AGENTS.md', 'LICENSE', '.gitignore')}
    files.update((ROOT / 'docs').glob('*.md'))
    files.update((ROOT / 'docs/reviews').glob('*-public-*.md'))
    files.update((ROOT / 'docs/design').glob('public-*.png'))
    files.update(ROOT / p for p in ('docs/design/README.md', 'docs/design/prompts.json'))
    files.update(ROOT / p for p in ('Resources/AppIcon/README.md', 'Resources/AppIcon/source.png', 'Resources/AppIcon.icns'))
    for directory in ('contracts', 'examples', 'skills', 'plugins', 'templates', 'scripts'):
        files.update(p for p in (ROOT / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    return {p.resolve() for p in files}


def headings(path: Path) -> set[str]:
    used: dict[str, int] = {}
    result: set[str] = set()
    for title in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', path.read_text(), re.M):
        slug = re.sub(r'[`*_~]', '', title).lower()
        slug = re.sub(r'[^\w\-\s]', '', slug)
        slug = re.sub(r'\s', '-', slug)
        ordinal = used.get(slug, 0)
        used[slug] = ordinal + 1
        result.add(slug if ordinal == 0 else f'{slug}-{ordinal}')
    return result


def check() -> dict:
    errors: list[str] = []
    selected = public_files()
    report: dict = {'scope': 'public planning artifacts only; no product or host execution'}
    validators = {}
    examples = {}
    negatives = 0

    def reject(name: str, value: dict, label: str) -> None:
        nonlocal negatives
        if validators[name].is_valid(value):
            errors.append(f'{name}: invalid {label} was accepted')
        negatives += 1

    for path in sorted((ROOT / 'contracts').glob('*.schema.json')):
        name = path.name.removesuffix('.schema.json')
        schema = json.loads(path.read_text())
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        example = json.loads((ROOT / 'examples' / f'{name}.json').read_text())
        validators[name], examples[name] = validator, example
        errors.extend(f'{name}: {e.message}' for e in validator.iter_errors(example))
        invalid = copy.deepcopy(example)
        if isinstance(invalid, list):
            invalid[0]['unknown_field'] = True
        else:
            invalid['unknown_field'] = True
        reject(name, invalid, 'unknown field')

    for name, fields in [('group-reference', ('key', 'name')), ('agent-message-subject', ('key', 'title', 'project_name'))]:
        for field in fields:
            bad = copy.deepcopy(examples[name]); bad.pop(field)
            reject(name, bad, 'missing ' + field)
    for kind, key in [('triage', 'DEMO-E1'), ('epic', 'DEMO-T1'), ('triage', 'DEMO-T0')]:
        bad = copy.deepcopy(examples['group-reference']); bad.update(kind=kind, key=key)
        reject('group-reference', bad, 'wrong group key kind or number')
    for rel in ('skills/checklist/SKILL.md', 'plugins/checklist/skills/checklist-assistant/SKILL.md',
                'templates/project/AGENTS.checklist.md', 'templates/project/CLAUDE.checklist.md'):
        if 'KEY "Title"' not in (ROOT / rel).read_text():
            errors.append(rel + ': missing key/title reporting guidance')

    identity = examples['assistant-identity']
    grant = examples['assistant-grant']
    settings = examples['project-settings']
    for field, value in [('provider', 'uninstalled-client'), ('roles', ['implementer']),
                         ('permissions', ['human_approval']), ('personality_summary', 'App-created persona'),
                         ('agent_profile_id', '7595ed81-c2dc-4dbd-a7de-442856a86103'), ('state', 'active')]:
        bad = copy.deepcopy(identity); bad[field] = value
        reject('assistant-identity', bad, field)
    bad = copy.deepcopy(identity); bad['identity_provenance'] = 'host_verified'
    reject('assistant-identity', bad, 'verified host identity without proof receipt')
    bad = copy.deepcopy(identity); bad['verification_receipt_id'] = '7595ed81-c2dc-4dbd-a7de-442856a86103'
    reject('assistant-identity', bad, 'proof receipt on host-reported identity')
    for field, value in [('access_mode', 'worker'), ('surface', 'invented'), ('grant_revision', 0),
                         ('agent_profile_id', '7595ed81-c2dc-4dbd-a7de-442856a86103')]:
        bad = copy.deepcopy(grant); bad[field] = value
        reject('assistant-grant', bad, field)
    bad = copy.deepcopy(grant); bad['projects'][0]['claim_work'] = True
    reject('assistant-grant', bad, 'work authority')
    bad = copy.deepcopy(grant); bad['projects'].append(copy.deepcopy(bad['projects'][0]))
    reject('assistant-grant', bad, 'identical duplicate membership')
    bad = copy.deepcopy(grant); bad['projects'][0].pop('receive_messages')
    reject('assistant-grant', bad, 'missing direct-message permission')
    for field in ('assistant_id', 'agent_profile_id', 'personality_summary'):
        bad = copy.deepcopy(examples['project-binding']); bad[field] = 'not-a-worker-identity'
        reject('project-binding', bad, f'worker binding {field}')
    direct = copy.deepcopy(grant)
    direct['projects'][0]['receive_messages'] = True
    direct['projects'][0]['receive_notifications'] = False
    if not validators['assistant-grant'].is_valid(direct):
        errors.append('Direct-message grant must be independent of ticket updates')
    future = copy.deepcopy(grant); future['adapter_registry_id'] = 'future.client'
    if not validators['assistant-grant'].is_valid(future):
        errors.append('Future adapter reference must be shape-valid data, never an enabled implementation')

    for change in ('remove_work', 'remote_icon', 'credential', 'bad_uuid'):
        bad = copy.deepcopy(settings)
        if change == 'remove_work': bad['capture']['enabled_kinds'] = ['bug']
        elif change == 'remote_icon': bad['identity']['icon']['url'] = 'https://example.invalid/avatar'
        elif change == 'credential': bad['pairing_secret'] = 'not-a-real-secret'
        else: bad['project_id'] = 'invalid'
        reject('project-settings', bad, change)
    for field, value in [('request_spec', {}), ('purpose', 'questions'), ('blocking_scope', 'task'), ('target', {})]:
        bad = copy.deepcopy(examples['human-request']); bad[field] = value
        reject('human-request', bad, field)
    for field, value in [('type', 'single_choice'), ('type', 'long_text')]:
        bad = copy.deepcopy(examples['human-request']); bad['questions'][0][field] = value
        reject('human-request', bad, value)
    bad = copy.deepcopy(examples['human-request']); bad['questions'][0]['label'] = bad['questions'][0].pop('prompt')
    reject('human-request', bad, 'label instead of prompt')
    bad = copy.deepcopy(examples['human-request']); bad['file_requests'][0]['kind'] = 'file_or_directory'
    reject('human-request', bad, 'file_or_directory instead of either')

    project_id = examples['project-binding']['project_id']
    if settings['project_id'] != project_id or any(g['project_id'] != project_id for g in grant['projects']):
        errors.append('Synthetic project settings/grants/binding disagree')
    if grant['assistant_id'] != identity['assistant_id'] or grant['adapter_registry_id'] != identity['adapter_registry_id']:
        errors.append('Grant does not reference the synthetic host-owned assistant identity/adapter')
    if len({g['project_id'] for g in grant['projects']}) != len(grant['projects']):
        errors.append('Conflicting duplicate project membership in example; service must reject keyed duplicates')
    if settings['capture']['default_kind'] not in settings['capture']['enabled_kinds']:
        errors.append('Default capture kind is disabled')
    taxonomy = examples['taxonomy']
    statuses = {s['id']: s for s in taxonomy['statuses']}
    if len(statuses) != len(taxonomy['statuses']): errors.append('Duplicate status ID')
    for edge in taxonomy['transitions']:
        if edge['from'] not in statuses or edge['to'] not in statuses: errors.append('Unknown transition target')
    for category, status_id in taxonomy['defaults'].items():
        if status_id not in statuses or statuses[status_id]['category'] != category:
            errors.append('Invalid category default')
    if settings['references']['taxonomy_revision'] != taxonomy['revision']:
        errors.append('Settings taxonomy revision mismatch')
    if len([s for s in statuses.values() if s['category'] == 'deferred']) < 2:
        errors.append('Synthetic taxonomy must preserve multiple Parked types')
    policy = examples['project-policy']
    for role in policy['roles'].values():
        if not set(role['providers']) <= set(policy['allowed_providers']): errors.append('Role provider not permitted')
        if role['preferred_provider'] is not None and role['preferred_provider'] not in role['providers']:
            errors.append('Preferred provider is ineligible')

    skills = {'skills/checklist/SKILL.md': 'checklist',
              'plugins/checklist/skills/checklist-assistant/SKILL.md': 'checklist-assistant'}
    for rel, expected in skills.items():
        text = (ROOT / rel).read_text()
        front = re.match(r'^---\n(.*?)\n---\n', text, re.S)
        metadata = yaml.safe_load(front.group(1)) if front else None
        if not isinstance(metadata, dict) or metadata.get('name') != expected:
            errors.append(f'{rel}: wrong/missing generic skill name')
        elif not isinstance(metadata.get('description'), str) or not 1 <= len(metadata['description']) <= 1024:
            errors.append(f'{rel}: invalid description')

    package = ROOT / 'plugins/checklist'
    manifest = json.loads((package / '.codex-plugin/plugin.json').read_text())
    for field in ('skills', 'mcpServers'):
        target = (package / manifest[field]).resolve()
        if not manifest[field].startswith('./') or not target.is_relative_to(package) or not target.exists():
            errors.append(f'Plugin {field} path escapes/is missing')
    server = json.loads((package / '.mcp.json').read_text())['mcpServers']['checklist']
    if server['type'] != 'stdio' or server['args'] != ['mcp', '--assistant', '--project', '@enabled']:
        errors.append('Local plugin must use restricted assistant access to owner-enabled projects')
    if server['command'] != '/Applications/Checklist.app/Contents/MacOS/checklist':
        errors.append('Unexpected planned app executable')

    links = 0
    for path in sorted(selected):
        if not path.exists(): errors.append(f'Missing public file: {path.relative_to(ROOT)}'); continue
        if path.suffix in {'.png', '.icns'}: continue
        if path.suffix == '.json': json.loads(path.read_text())
        body = path.read_text()
        for label, match in private_identifiers(body):
            line = body.count('\n', 0, match.start()) + 1
            errors.append(f'Concrete private identifier ({label}): {path.relative_to(ROOT)}:{line}')
        if path.suffix != '.md': continue
        if re.search(r'^(<<<<<<<|=======|>>>>>>>)', body, re.M): errors.append(f'Conflict marker: {path.relative_to(ROOT)}')
        if any(line.rstrip() != line for line in body.splitlines()): errors.append(f'Trailing whitespace: {path.relative_to(ROOT)}')
        for match in re.finditer(r'!?\[[^\]\n]*\]\((<[^>]+>|[^)\n]+)\)', body):
            target = unquote(match.group(1).strip().strip('<>'))
            if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*://', target) or target.startswith(('mailto:', 'app:')): continue
            target, _, fragment = target.partition('#')
            line = None; line_ref = re.match(r'^(.*):(\d+)$', target)
            if line_ref: target, line = line_ref.group(1), int(line_ref.group(2))
            destination = (path.parent / target).resolve() if target else path
            permitted = destination in selected or (destination.is_dir() and any(p.is_relative_to(destination) for p in selected))
            if not destination.exists() or not permitted:
                errors.append(f'Nonpublic/missing link: {path.relative_to(ROOT)} -> {target}'); continue
            links += 1
            if line and (not destination.is_file() or line > len(destination.read_text().splitlines())):
                errors.append(f'Line reference out of range: {path.relative_to(ROOT)}')
            if fragment and destination.suffix == '.md' and fragment not in headings(destination):
                errors.append(f'Heading missing: {path.relative_to(ROOT)} -> {target}#{fragment}')

    concept_data = json.loads((ROOT / 'docs/design/prompts.json').read_text())
    outputs = [v for v in concept_data['outputs'] if v.get('selected')]
    if len(outputs) != 2: errors.append('Expected two current public synthetic concepts')
    for output in outputs:
        path = ROOT / 'docs/design' / output['path']; data = path.read_bytes()
        if path.resolve() not in selected or not path.name.startswith('public-'):
            errors.append('Private image in public provenance')
        if data[:8] != b'\x89PNG\r\n\x1a\n' or list(struct.unpack('>II', data[16:24])) != output['pixels']:
            errors.append('Image dimensions/format differ from recorded output')
        if hashlib.sha256(data).hexdigest() != output['sha256']:
            errors.append('Image pixels changed after provenance capture')
        if not output.get('prompt') or not output.get('prompt_is_sanitized'):
            errors.append('Missing sanitized public prompt provenance')

    report.update({'schema_example_pairs': len(validators), 'invalid_shape_cases_rejected': negatives,
                   'public_files': len(selected), 'public_markdown_links': links,
                   'generic_skills': list(skills.values()), 'selected_public_concepts': len(outputs),
                   'plugin_status': 'prepared structure only; executable/host/event qualification unverified',
                   'semantic_status': 'example references checked; runtime invariants remain acceptance gates',
                   'errors': errors})
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list-files', action='store_true', help='List candidate public files; not a Git staging assertion')
    args = parser.parse_args()
    if args.list_files:
        print('\n'.join(str(p.relative_to(ROOT)) for p in sorted(public_files())))
        return 0
    result = check()
    print(json.dumps(result, indent=2))
    return bool(result['errors'])


if __name__ == '__main__':
    sys.exit(main())
