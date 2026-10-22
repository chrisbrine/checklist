"""Shared text-only privacy rules for public preparation and planning checks."""
import re

UUID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
# Reserved fixture namespace: zero-filled UUIDs with only the last 12 bits set.
SYNTHETIC_UUID = re.compile(r'00000000-0000-0000-0000-000000000[0-9a-f]{3}', re.I)
# Token boundaries keep UUID-shaped fragments embedded in longer identifiers inert.
START, END = r'(?<![A-Za-z0-9])', r'(?![A-Za-z0-9])'
PATTERNS = {
    'home_path': r'/(?:Users|home)/[A-Za-z0-9_.-]+',
    'native_socket': r'/tmp/cc-socks(?:-\d+)?/\d+\.sock',
    'native_session': r'(?<![A-Za-z_])session_[A-Za-z0-9]{15,}',
    'private_scratch': r'/private/tmp/claude-\d+',
    'credential': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'codex_actor_uuid': START + r'auto-codex/' + UUID + END,
    'claude_actor_uuid': START + r'auto-claude-[0-9a-f]+/[^\s\"\'<>]*:' + UUID + END,
    'codex_thread_uuid': START + r'[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' + END,
    # Split the known installation ID so the rule itself is safe to export.
    'live_project_uuid': START + ('a3854aea-' 'b62c-4fbc-' 'b86b-40ce4a4f0cd6') + END,
}


def private_identifiers(body: str):
    """Yield labels and matches, without including private bytes in diagnostics."""
    for label, pattern in PATTERNS.items():
        for match in re.finditer(pattern, body, re.I):
            if label in {'codex_actor_uuid', 'claude_actor_uuid'}:
                identities = re.findall(UUID, match.group(), re.I)
                if all(SYNTHETIC_UUID.fullmatch(value) for value in identities):
                    continue
            yield label, match
