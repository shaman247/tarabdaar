#!/usr/bin/env python3
"""Pin guard routing and failure propagation without compiling either package."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        (self.repo / 'tools').mkdir()
        for script in ('pre-commit.sh', 'install-hooks.sh', 'build-mac.sh'):
            shutil.copy2(ROOT / 'tools' / script, self.repo / 'tools' / script)
        self.bin = self.repo / 'bin'
        self.bin.mkdir()
        self.calls = self.repo / 'calls'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        CALLS=str(self.calls))
        self.git('init', '-q')
        self.write_script(self.bin / 'swift', '''
if [ "$1" = run ]; then
    printf '%s\\n' "${SWIFT_OUTPUT:-}"
    exit "${SWIFT_RC:-0}"
fi
printf '%s\\n' "$*" >> "$CALLS"
case "$*" in
    *TarabdaarCore*) exit "${CORE_RC:-0}" ;;
    *SarangiKit*) exit "${SARANGI_RC:-0}" ;;
esac
''')
        self.write_script(self.repo / 'tools/test-full.sh', '''
echo full >> "$CALLS"
exit "${CORE_RC:-0}"
''')
        self.write_script(self.bin / 'xcodebuild', '''
printf '%s\\n' "${XCODE_OUTPUT:-}"
exit "${XCODE_RC:-0}"
''')
        # The generator is outside this test's contract.
        (self.repo / 'tools/gen_docs_html.py').write_text('')

    def write_script(self, path, body):
        path.write_text('#!/bin/bash\nset -euo pipefail\n' + body)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env,
                              check=True, text=True, capture_output=True)

    def stage(self, path):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_text('fixture')
        self.git('add', '--', path)

    def run_script(self, script, **env):
        return subprocess.run(['bash', str(self.repo / 'tools' / script)],
                              cwd=self.repo, env=dict(self.env, **env),
                              text=True, capture_output=True)

    def assert_guard(self, full, **env):
        self.calls.unlink(missing_ok=True)
        result = self.run_script('pre-commit.sh', **env)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls, [
            'full' if full else 'test --package-path Packages/TarabdaarCore',
            'test --package-path Packages/SarangiKit',
        ])
        return result

    def test_sound_paths_use_full_guard(self):
        for path in (
            'Packages/SarangiKit/Sources/SarangiKit/Bow/BowEngine+Taraf.swift',
            'Packages/SarangiKit/Sources/SarangiKit/Bow/DualTaraf.swift',
            'Packages/SarangiKit/Sources/SarangiKit/Tanpura/TanpuraTables.swift',
            'Packages/SarangiKit/Sources/SarangiKit/DSP/FXChain.swift',
            'Packages/SarangiKit/Sources/SarangiKit/Resources/new fit\nroom.f32',
            'Packages/SarangiKit/Tests/SarangiKitTests/NewContractTests.swift',
            'Packages/TarabdaarCore/Tests/TarabdaarCoreTests/TarafCoupleTests.swift',
            'Packages/TarabdaarCore/Sources/TarabdaarCore/AudioEngine+PluckedVoices.swift',
            'Packages/TarabdaarCore/Sources/TarabdaarCore/ParamRegistry.swift',
            'Packages/TarabdaarCore/Package.swift',
            'TarabdaarMac/AppController.swift',
            'TarabdaarMac/StringParamStore.swift',
            'TarabdaarMac/Default.json',
            'presets/example.tarabdaar',
            'tools/pre-commit.sh',
        ):
            with self.subTest(path=path):
                self.git('read-tree', '--empty')
                self.stage(path)
                self.assertEqual(self.assert_guard(True).returncode, 0)

    def test_non_sound_changes_use_both_fast_packages(self):
        self.stage('docs/packaging.md')
        self.stage('TarabdaarMac/Views/SetupView.swift')
        self.assertEqual(self.assert_guard(False).returncode, 0)

    def test_deletion_and_rename_out_of_guarded_directory(self):
        path = 'Packages/SarangiKit/Sources/SarangiKit/DSP/Old.swift'
        self.stage(path)
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'fixture')
        self.git('mv', path, 'moved.swift')
        self.assertEqual(self.assert_guard(True).returncode, 0)
        self.git('reset', '--hard', '-q', 'HEAD')
        self.git('rm', '-q', path)
        self.assertEqual(self.assert_guard(True).returncode, 0)

    def test_either_failure_fails_without_skipping_second_package(self):
        for full in (False, True):
            self.stage('Packages/SarangiKit/guard' if full else 'README.md')
            for env in ({'CORE_RC': '7'}, {'SARANGI_RC': '8'},
                        {'CORE_RC': '7', 'SARANGI_RC': '8'}):
                with self.subTest(full=full, env=env):
                    result = self.assert_guard(full, **env)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('FAILED', result.stderr)

    def test_installer_respects_configured_hooks_directory(self):
        self.git('config', 'core.hooksPath', 'custom-hooks')
        result = self.run_script('install-hooks.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.stage('README.md')
        hook = self.repo / 'custom-hooks/pre-commit'
        self.assertTrue(os.access(hook, os.X_OK))
        result = subprocess.run([str(hook)], cwd=self.repo, env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Packages/SarangiKit', self.calls.read_text())

    def test_build_surfaces_and_fails_actionable_warnings(self):
        for variable in ('SWIFT_OUTPUT', 'XCODE_OUTPUT'):
            for warning in (
                'warning: associated value has non-sendable type',
                'warning: variable was never used; consider replacing with _',
                'warning: appintents has an unexpected error',
            ):
                with self.subTest(variable=variable, warning=warning):
                    result = self.run_script('build-mac.sh', **{variable: warning})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(warning, result.stdout)

    def test_build_allows_only_known_metadata_warning(self):
        result = self.run_script('build-mac.sh', XCODE_OUTPUT=(
            '2026 appintentsmetadataprocessor warning: Metadata extraction skipped. '
            'No AppIntents.framework dependency found.'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('build succeeded', result.stdout)

    def test_build_preserves_tool_failure_without_compiler_diagnostic(self):
        for prefix in ('SWIFT', 'XCODE'):
            with self.subTest(prefix=prefix):
                result = self.run_script('build-mac.sh', **{
                    f'{prefix}_OUTPUT': 'tool failed to launch', f'{prefix}_RC': '23'})
                self.assertEqual(result.returncode, 23)
                self.assertIn('tool failed to launch', result.stdout)


if __name__ == '__main__':
    unittest.main()
