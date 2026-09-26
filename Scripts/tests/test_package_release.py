"""Exercise release publication gates with fake build/signing tools, never real credentials."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, plistlib, shlex, shutil, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['TOOL_TRACE'], 'a') as trace:
    trace.write(json.dumps([name, *args]) + '\n')
if name == 'security':
    pass  # Deliberately no identities: tests must never read the user's keychain.
elif name == 'xcodebuild':
    products = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release'
    contents = products / 'Mimic.app/Contents'
    contents.mkdir(parents=True, exist_ok=True)
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleShortVersionString': os.environ.get('FAKE_APP_VERSION', '0.12.0')}))
    cli = products / 'mimic'
    description = 'mimic ' + os.environ.get('FAKE_CLI_VERSION', '0.12.0') + ' (control API v1)'
    cli.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(description) + '\n')
    cli.chmod(0o755)
elif name == 'codesign':
    failure = os.environ.get('FAKE_BAD_SIGNATURE')
    if failure == 'all' or (failure == 'cli' and args[-1].endswith('/mimic')):
        raise SystemExit(1)
elif name == 'ditto':
    source, destination = map(Path, args[-2:])
    if source.is_dir():
        shutil.copytree(source, destination, dirs_exist_ok=True)
    else:
        shutil.copyfile(source, destination)
elif name == 'lipo':
    print('arm64 x86_64')
elif name == 'pkgbuild':
    if '--analyze' in args:
        Path(args[-1]).write_bytes(plistlib.dumps([
            {'RootRelativeBundlePath': 'Applications/Mimic.app', 'BundleIsRelocatable': True}]))
    else:
        Path(args[-1]).write_bytes(b'component fixture')
elif name == 'productbuild':
    Path(args[-1]).write_bytes(b'package fixture')
elif name == 'productsign':
    shutil.copyfile(args[-2], args[-1])
elif name == 'xcrun':
    if args[0] == 'notarytool':
        print(json.dumps({'id': 'fixture-submission', 'status': os.environ.get('FAKE_NOTARY_STATUS', 'Accepted')}))
    elif args[:2] == ['stapler', 'validate'] and os.environ.get('FAKE_INVALID_TICKET'):
        raise SystemExit(1)
elif name == 'spctl':
    # A misleading text match must not override the tool's failing exit status.
    print('accepted' if os.environ.get('FAKE_REJECT_PACKAGE') else 'fixture: accepted')
    raise SystemExit(1 if os.environ.get('FAKE_REJECT_PACKAGE') else 0)
else:
    raise SystemExit('Unexpected tool: ' + name)
'''


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('zsh'), 'macOS packaging script')
class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mimic-package-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / 'Scripts'
        scripts.mkdir()
        source = Path(__file__).resolve().parents[1] / 'package_release.sh'
        self.script = scripts / source.name
        shutil.copyfile(source, self.script)
        (self.root / 'Project.swift').write_text('"MARKETING_VERSION": "0.12.0"\n')
        domain = self.root / 'Sources/Domain/Control'
        domain.mkdir(parents=True)
        (domain / 'ControlResult.swift').write_text('static let releaseVersion = "0.12.0"\n')
        self.bin = self.root / 'tools'
        self.bin.mkdir()
        tool = self.bin / 'fake-tool'
        tool.write_text(FAKE_TOOL)
        tool.chmod(0o755)
        for name in ('security', 'xcodebuild', 'codesign', 'ditto', 'lipo', 'pkgbuild',
                     'productbuild', 'productsign', 'xcrun', 'spctl'):
            (self.bin / name).symlink_to(tool)
        self.trace = self.root / 'trace.jsonl'
        self.release = self.root / '.artifacts/release/Mimic-0.12.0.pkg'

    def run_package(self, **settings):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('MIMIC_', 'FAKE_'))}
        env.update(PATH=str(self.bin) + os.pathsep + env['PATH'], TOOL_TRACE=str(self.trace))
        env.update(settings)
        return subprocess.run(['zsh', str(self.script)], env=env, text=True,
                              capture_output=True, timeout=20)

    def signed_package(self, **settings):
        return self.run_package(MIMIC_SIGN_APP='fixture app identity',
                                MIMIC_SIGN_INSTALLER='fixture installer identity',
                                MIMIC_NOTARY_PROFILE='fixture profile', **settings)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_unsigned_package_stays_in_development_output(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.release.exists())
        self.assertTrue((self.root / '.artifacts/package/Mimic-0.12.0.pkg').is_file())
        self.assertIn('Development package only', result.stdout)

    def test_signing_without_notarization_stays_in_development_output(self):
        result = self.run_package(MIMIC_SIGN_APP='fixture app identity',
                                  MIMIC_SIGN_INSTALLER='fixture installer identity')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.release.exists())
        self.assertTrue(any(call[0] == 'productsign' for call in self.calls()))

    def test_incomplete_signing_fails_before_build(self):
        result = self.run_package(MIMIC_SIGN_APP='fixture app identity')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Set both', result.stderr)
        self.assertFalse(any(call[0] == 'xcodebuild' for call in self.calls()))

    def test_missing_team_identity_never_downgrades_to_unsigned(self):
        result = self.run_package(MIMIC_TEAM_ID='FIXTURE123')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no unsigned replacement', result.stderr)
        self.assertFalse(any(call[0] == 'xcodebuild' for call in self.calls()))

    def test_built_versions_must_match_the_package(self):
        for variable in ('FAKE_APP_VERSION', 'FAKE_CLI_VERSION'):
            with self.subTest(variable=variable):
                result = self.run_package(**{variable: '0.11.0'})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Built app/CLI versions do not match', result.stderr)
                self.assertFalse(self.release.exists())

    def test_invalid_signature_refuses_packaging(self):
        result = self.signed_package(FAKE_BAD_SIGNATURE='all')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == 'pkgbuild' for call in self.calls()))

    def test_invalid_cli_signature_is_checked_independently(self):
        result = self.signed_package(FAKE_BAD_SIGNATURE='cli')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CLI signature verification failed', result.stderr)
        self.assertFalse(any(call[0] == 'pkgbuild' for call in self.calls()))

    def test_notary_status_must_be_accepted_even_with_exit_zero(self):
        result = self.signed_package(FAKE_NOTARY_STATUS='Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Notarization was not accepted', result.stderr)
        self.assertFalse(self.release.exists())
        self.assertFalse(any(call[:2] == ['xcrun', 'stapler'] for call in self.calls()))

    def test_invalid_ticket_never_publishes(self):
        result = self.signed_package(FAKE_INVALID_TICKET='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.release.exists())

    def test_gatekeeper_refusal_preserves_existing_release(self):
        self.release.parent.mkdir(parents=True)
        self.release.write_bytes(b'previous accepted package')
        result = self.signed_package(FAKE_REJECT_PACKAGE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Gatekeeper rejected', result.stderr)
        self.assertEqual(self.release.read_bytes(), b'previous accepted package')

    def test_accepted_package_publishes_only_after_ticket_validation(self):
        import plistlib
        result = self.signed_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.release.read_bytes(), b'package fixture')
        calls = self.calls()
        self.assertTrue(any(call[:3] == ['xcrun', 'stapler', 'validate'] for call in calls))
        components = plistlib.loads((self.root / '.artifacts/package/components.plist').read_bytes())
        self.assertIs(components[0]['BundleIsRelocatable'], False)
        self.assertEqual(components[0]['BundleOverwriteAction'], 'upgrade')
        package_call = next(call for call in calls if call[0] == 'pkgbuild' and '--analyze' not in call)
        self.assertIn('--component-plist', package_call)
        self.assertEqual(package_call[package_call.index('--component-plist') + 1],
                         str(self.root / '.artifacts/package/components.plist'))
        self.assertFalse(any('--scripts' in call for call in calls if call[0] == 'pkgbuild'))


if __name__ == '__main__':
    unittest.main()
