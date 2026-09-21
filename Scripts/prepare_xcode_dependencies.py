#!/usr/bin/env python3
"""Normalize only Tuist-generated dependencies; never edit upstream package sources."""
import argparse
from pathlib import Path
import re
import tempfile
import xml.etree.ElementTree as ET

FLOOR = re.compile(r'(MACOSX_DEPLOYMENT_TARGET\s*=\s*)"?(\d+(?:\.\d+)*)"?(\s*;)')


def normalize_targets(text):
    def replace(match):
        if tuple(map(int, match[2].split('.'))) < (12, 0):
            return match[1] + '12.0' + match[3]
        return match[0]
    return FLOOR.sub(replace, text)


def normalize(root, check=False):
    derived = root / 'Tuist/.build/tuist-derived'
    workspace = root / 'Mimic.xcworkspace/contents.xcworkspacedata'
    if derived.is_symlink() or not derived.is_dir() or not workspace.is_file():
        raise RuntimeError('Generate Mimic.xcworkspace before preparing its dependencies.')
    changes = 0
    for ref in ET.parse(workspace).iter('FileRef'):
        location = ref.get('location', '')
        prefix = 'group:Tuist/.build/tuist-derived/'
        if not location.startswith(prefix):
            continue
        relative = Path(location[len(prefix):])
        parts = relative.parts
        if relative.is_absolute() or '..' in parts or not parts:
            raise RuntimeError(f'Unsafe generated reference: {location}')
        parent = derived
        for part in parts:
            matches = [p for p in parent.iterdir() if p.name.casefold() == part.casefold()]
            if len(matches) != 1:
                raise RuntimeError(f'Missing or ambiguous generated path: {parent / part}')
            actual = matches[0]
            if actual.is_symlink():
                raise RuntimeError(f'Refusing to modify a symlink: {actual}')
            if actual.name != part:
                changes += 1
                print(f'Path casing: {actual.name} -> {part}')
                if check:
                    parent = actual
                    continue
                # Two-step rename also works on case-insensitive APFS. No files are deleted.
                with tempfile.TemporaryDirectory(prefix='.mimic-case-', dir=parent) as staging:
                    temporary = Path(staging) / actual.name
                    actual.rename(temporary)
                    temporary.rename(parent / part)
            parent = parent / part

    projects = list(derived.glob('*/*.xcodeproj/project.pbxproj'))
    if not projects:
        raise RuntimeError('No generated dependency projects found.')
    for project in projects:
        if project.is_symlink() or not project.resolve().is_relative_to(derived.resolve()):
            raise RuntimeError(f'Refusing a dependency project outside the generated directory: {project}')
        original = project.read_text()
        updated = normalize_targets(original)
        if original != updated:
            changes += 1
            print(f'Deployment floor: {project.parent.name}')
            if not check:
                project.write_text(updated)
    if check and changes:
        raise RuntimeError(f'{changes} generated dependency corrections required.')
    print(f'Checked {len(projects)} dependency projects; {changes} corrections' + (' required.' if check else ' applied.'))


def self_test():
    # Literal expectations: reverting the transformation must make these assertions fail.
    assert normalize_targets('MACOSX_DEPLOYMENT_TARGET = 10.13;') == 'MACOSX_DEPLOYMENT_TARGET = 12.0;'
    assert normalize_targets('MACOSX_DEPLOYMENT_TARGET = "11.0";') == 'MACOSX_DEPLOYMENT_TARGET = 12.0;'
    for version in ['12.0', '14.0', '26.0']:
        text = f'MACOSX_DEPLOYMENT_TARGET = {version};'
        assert normalize_targets(text) == text
    assert normalize_targets('IPHONEOS_DEPLOYMENT_TARGET = 10.0;') == 'IPHONEOS_DEPLOYMENT_TARGET = 10.0;'
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        project = root / 'Tuist/.build/tuist-derived/Vapor/vapor.xcodeproj'
        project.mkdir(parents=True)
        (project / 'project.pbxproj').write_text('MACOSX_DEPLOYMENT_TARGET = 10.15;')
        workspace = root / 'Mimic.xcworkspace'
        workspace.mkdir()
        (workspace / 'contents.xcworkspacedata').write_text(
            '<Workspace><FileRef location="group:Tuist/.build/tuist-derived/vapor/vapor.xcodeproj"/></Workspace>')
        try:
            normalize(root, check=True)
        except RuntimeError:
            pass
        else:
            raise AssertionError('Negative control did not detect broken generated settings')
        normalize(root)
        assert 'vapor' in [p.name for p in (root / 'Tuist/.build/tuist-derived').iterdir()]
        assert (root / 'Tuist/.build/tuist-derived/vapor/vapor.xcodeproj/project.pbxproj').read_text() == 'MACOSX_DEPLOYMENT_TARGET = 12.0;'
        normalize(root, check=True)
    print('Self-tests passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        normalize(Path(__file__).resolve().parent.parent, check=args.check)
