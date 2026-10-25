"""Exercise the Mac App Store archive checks and export options with fake tools, never real credentials."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, plistlib, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['TOOL_TRACE'], 'a') as trace:
    trace.write(json.dumps([name, *args]) + '\n')
def setting(key):
    return next((arg.split('=', 1)[1] for arg in args if arg.startswith(key + '=')), '')
if name == 'security':
    if os.environ.get('FAKE_IDENTITIES'):
        print('  1) AAAA "Apple Distribution: Fixture Ltd (FIXTURE123)"')
        print('  2) BBBB "3rd Party Mac Developer Installer: Fixture Ltd (FIXTURE123)"')
elif name == 'xcodebuild' and 'archive' in args:
    archive = Path(args[args.index('-archivePath') + 1])
    app = archive / 'Products/Applications/Mimic.app/Contents'
    (app / 'Resources').mkdir(parents=True, exist_ok=True)
    (app / 'Resources/PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({'NSPrivacyTracking': False}))
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleShortVersionString': '0.12.0',
        'CFBundleVersion': setting('CURRENT_PROJECT_VERSION'),
        'MimicAppStoreBuild': os.environ.get('FAKE_APP_STORE_VALUE', setting('MIMIC_APP_STORE')),
    }))
    info = {'ArchiveVersion': 2}
    if os.environ.get('FAKE_GENERIC_ARCHIVE'):
        cli = archive / 'Products/usr/local/bin'
        cli.mkdir(parents=True)
        (cli / 'mimic').write_text('fixture')
    else:
        info['ApplicationProperties'] = {'ApplicationPath': 'Applications/Mimic.app'}
    (archive / 'Info.plist').write_bytes(plistlib.dumps(info))
elif name == 'xcodebuild' and '-exportArchive' in args:
    options = plistlib.loads(Path(args[args.index('-exportOptionsPlist') + 1]).read_bytes())
    export = Path(args[args.index('-exportPath') + 1])
    export.mkdir(parents=True, exist_ok=True)
    if options['destination'] == 'export':
        (export / 'Mimic.pkg').write_bytes(b'store package fixture')
elif name == 'codesign':
    sys.stdout.buffer.write(plistlib.dumps(
        {'com.apple.security.app-sandbox': not os.environ.get('FAKE_UNSANDBOXED')}))
else:
    raise SystemExit('Unexpected tool: ' + name + ' ' + ' '.join(args))
'''


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('zsh'), 'macOS packaging script')
class PackageAppStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mimic-app-store-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / 'Scripts'
        scripts.mkdir()
        source = Path(__file__).resolve().parents[1] / 'package_app_store.sh'
        self.script = scripts / source.name
        shutil.copyfile(source, self.script)
        (self.root / 'Project.swift').write_text(
            '"MACOSX_DEPLOYMENT_TARGET": "26.0",\n"MARKETING_VERSION": "0.12.0"\n')
        domain = self.root / 'Sources/Domain/Control'
        domain.mkdir(parents=True)
        (domain / 'ControlResult.swift').write_text('static let releaseVersion = "0.12.0"\n')
        self.bin = self.root / 'tools'
        self.bin.mkdir()
        tool = self.bin / 'fake-tool'
        tool.write_text(FAKE_TOOL)
        tool.chmod(0o755)
        for name in ('security', 'xcodebuild', 'codesign'):
            (self.bin / name).symlink_to(tool)
        self.trace = self.root / 'trace.jsonl'
        self.key = self.root / 'AuthKey_FIXTURE.p8'
        self.key.write_text('not a key')

    def run_script(self, **settings):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('MIMIC_', 'FAKE_'))}
        env.update(PATH=str(self.bin) + os.pathsep + env['PATH'], TOOL_TRACE=str(self.trace),
                   MIMIC_BUILD_NUMBER='42')
        env.update(settings)
        return subprocess.run(['zsh', str(self.script)], env=env, text=True,
                              capture_output=True, timeout=20)

    def calls(self, tool=None):
        if not self.trace.exists():
            return []
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        return [call for call in calls if tool is None or call[0] == tool]

    def export_options(self):
        return plistlib.loads((self.root / '.artifacts/app-store/ExportOptions.plist').read_bytes())

    def test_without_a_team_it_archives_the_store_variant_and_stops(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        builds = self.calls('xcodebuild')
        self.assertEqual(len(builds), 1)
        archive = builds[0]
        self.assertIn('archive', archive)
        for setting in ('MIMIC_APP_STORE=YES', 'CURRENT_PROJECT_VERSION=42',
                        'MACOSX_DEPLOYMENT_TARGET=26.0', 'CODE_SIGN_IDENTITY=-'):
            self.assertIn(setting, archive)
        self.assertIn('Nothing was signed or uploaded', result.stdout)

    def test_a_generic_archive_is_refused(self):
        result = self.run_script(FAKE_GENERIC_ARCHIVE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not an app archive', result.stderr)

    def test_the_direct_variant_is_refused(self):
        result = self.run_script(FAKE_APP_STORE_VALUE='NO')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not built as the App Store variant', result.stderr)

    def test_an_unsandboxed_app_is_refused(self):
        result = self.run_script(FAKE_UNSANDBOXED='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not sandboxed', result.stderr)

    def test_a_malformed_build_number_fails_before_building(self):
        result = self.run_script(MIMIC_BUILD_NUMBER='0.12.0-beta')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls('xcodebuild'))

    def test_upload_without_a_team_fails_before_building(self):
        result = self.run_script(MIMIC_UPLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('needs MIMIC_TEAM_ID', result.stderr)
        self.assertFalse(self.calls('xcodebuild'))

    def test_a_partial_api_key_fails_before_building(self):
        result = self.run_script(MIMIC_TEAM_ID='FIXTURE123', MIMIC_ASC_KEY_ID='FIXTURE')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('all three', result.stderr)
        self.assertFalse(self.calls('xcodebuild'))

    def test_a_named_profile_needs_both_certificates(self):
        result = self.run_script(MIMIC_TEAM_ID='FIXTURE123', MIMIC_APP_STORE_PROFILE='Mimic App Store')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Requested signing identities were not found', result.stderr)
        self.assertFalse(self.calls('xcodebuild'))

    def test_a_named_profile_exports_with_manual_signing(self):
        result = self.run_script(MIMIC_TEAM_ID='FIXTURE123', MIMIC_APP_STORE_PROFILE='Mimic App Store',
                                 FAKE_IDENTITIES='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.export_options(), {
            'method': 'app-store-connect',
            'teamID': 'FIXTURE123',
            'destination': 'export',
            'manageAppVersionAndBuildNumber': False,
            'uploadSymbols': True,
            'signingStyle': 'manual',
            'signingCertificate': 'Apple Distribution: Fixture Ltd (FIXTURE123)',
            'installerSigningCertificate': '3rd Party Mac Developer Installer: Fixture Ltd (FIXTURE123)',
            'provisioningProfiles': {'devxa.Mimic': 'Mimic App Store'},
        })
        export = next(call for call in self.calls('xcodebuild') if '-exportArchive' in call)
        self.assertNotIn('-allowProvisioningUpdates', export)
        self.assertIn(str(self.root / '.artifacts/app-store/export/Mimic.pkg'), result.stdout)

    def test_an_upload_with_automatic_signing_passes_the_api_key(self):
        result = self.run_script(MIMIC_TEAM_ID='FIXTURE123', MIMIC_UPLOAD='1',
                                 MIMIC_ASC_KEY_PATH=str(self.key), MIMIC_ASC_KEY_ID='FIXTUREKEY',
                                 MIMIC_ASC_ISSUER_ID='fixture-issuer')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        options = self.export_options()
        self.assertEqual(options['destination'], 'upload')
        self.assertEqual(options['signingStyle'], 'automatic')
        self.assertNotIn('provisioningProfiles', options)
        export = next(call for call in self.calls('xcodebuild') if '-exportArchive' in call)
        self.assertIn('-allowProvisioningUpdates', export)
        for flag, value in (('-authenticationKeyPath', str(self.key)),
                            ('-authenticationKeyID', 'FIXTUREKEY'),
                            ('-authenticationKeyIssuerID', 'fixture-issuer')):
            self.assertEqual(export[export.index(flag) + 1], value)
        self.assertIn('Uploaded Mimic 0.12.0 (42)', result.stdout)


if __name__ == '__main__':
    unittest.main()
