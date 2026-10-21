"""子CLIプロファイルの解決(POSIX版スクリプト共通)。

import して load_profile(root) を使うか、`python3 childprofile.py <root>` で 7 行を stdout に出す
(name・output_format・tool_activity_pattern・tool_call_pattern・permission_denied_pattern・
provider_error_pattern・agents_md_imports を true/false)。
組み込み定義は同じディレクトリの child-profiles.json、利用先定義は
<root>/.agents/workflow/child-profiles.json(同名エントリは組み込みを丸ごと置き換える)。
"""
import json
import os
import sys

DEFAULT_PROFILE = 'auto'
PATTERN_KEYS = (
    'tool_activity_pattern',
    'tool_call_pattern',
    'permission_denied_pattern',
    'provider_error_pattern',
)


class ProfileError(Exception):
    pass


def _read_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def _load_definitions(path):
    try:
        data = _read_json(path)
    except (OSError, ValueError) as e:
        raise ProfileError('Cannot read child profiles: %s (%s)' % (path, e))
    if not isinstance(data, dict):
        raise ProfileError('Child profiles must be a JSON object: %s' % path)
    for name, value in data.items():
        if not isinstance(value, dict):
            raise ProfileError('Child profile must be a JSON object: %s (%s)' % (name, path))
    return data


def _read_child_agent(root):
    path = os.path.join(root, '.agents', 'workflow', 'config.json')
    try:
        config = _read_json(path)
    except (OSError, ValueError):
        return '', ''
    child = config.get('child_agent') if isinstance(config, dict) else None
    if not isinstance(child, dict):
        return '', ''
    profile = child.get('profile')
    template = child.get('command_template')
    return (profile if isinstance(profile, str) else ''), (template if isinstance(template, str) else '')


def load_profile(root):
    name, command_template = _read_child_agent(root)
    name = name or DEFAULT_PROFILE

    builtin = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'child-profiles.json')
    definitions = _load_definitions(builtin)
    custom = os.path.join(root, '.agents', 'workflow', 'child-profiles.json')
    if os.path.isfile(custom):
        definitions.update(_load_definitions(custom))

    if name not in definitions:
        raise ProfileError('Unknown child profile: %s (defined: %s)' % (name, ', '.join(sorted(definitions))))
    entry = definitions[name]

    output_format = entry.get('output_format', '')
    if output_format == 'auto':
        output_format = 'claude-stream-json' if 'stream-json' in command_template else 'text'
    if output_format not in ('text', 'claude-stream-json'):
        raise ProfileError('Invalid output_format in child profile %s: %s' % (name, output_format))

    result = {'name': name, 'output_format': output_format}
    for key in PATTERN_KEYS:
        value = entry.get(key, '')
        if not isinstance(value, str):
            value = ''
        if '\n' in value or '\r' in value:
            raise ProfileError('Pattern must be a single line: %s.%s' % (name, key))
        result[key] = value
    result['agents_md_imports'] = entry.get('agents_md_imports', False) is True
    return result


def main(argv):
    if len(argv) != 2:
        sys.stderr.write('Usage: childprofile.py <root>\n')
        return 1
    try:
        p = load_profile(argv[1])
    except ProfileError as e:
        sys.stderr.write('%s\n' % e)
        return 1
    lines = [
        p['name'],
        p['output_format'],
        p['tool_activity_pattern'],
        p['tool_call_pattern'],
        p['permission_denied_pattern'],
        p['provider_error_pattern'],
        'true' if p['agents_md_imports'] else 'false',
    ]
    sys.stdout.buffer.write(('\n'.join(lines) + '\n').encode('utf-8'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
