import base64
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

from _testkit import make_temp_dir, remove_tree

SCRIPT = Path(__file__).resolve().parent / 'configure_signing.py'
SECRET_NAMES = [
    'ANDROID_KEYSTORE_BASE64',
    'ANDROID_KEYSTORE_PASSWORD',
    'ANDROID_KEY_ALIAS',
    'ANDROID_KEY_PASSWORD',
]


class ConfigureSigningTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(make_temp_dir(prefix='duanju-signing-test-'))
        self.addCleanup(remove_tree, self.root)
        self.runner_temp = self.root / 'runner'
        self.runner_temp.mkdir()
        scripts_dir = self.root / 'scripts'
        scripts_dir.mkdir()
        self.script = scripts_dir / 'configure_signing.py'
        shutil.copyfile(SCRIPT, self.script)
        (self.root / 'android').mkdir()

    def run_script(self, secrets, args=()):
        env = {k: v for k, v in os.environ.items() if k not in SECRET_NAMES}
        env['RUNNER_TEMP'] = str(self.runner_temp)
        env.update(secrets)
        return subprocess.run(
            [sys.executable, str(self.script), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_ci_without_any_secrets_fails(self):
        result = self.run_script({})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('四个 Secrets', result.stderr)

    def test_ci_with_partial_secrets_fails(self):
        result = self.run_script({
            'ANDROID_KEYSTORE_BASE64': base64.b64encode(b'fake').decode(),
            'ANDROID_KEYSTORE_PASSWORD': 'pw',
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('四个 Secrets', result.stderr)

    def test_ci_with_all_secrets_configures_fixed_signing(self):
        keystore = b'fake-keystore-bytes'
        result = self.run_script({
            'ANDROID_KEYSTORE_BASE64': base64.b64encode(keystore).decode(),
            'ANDROID_KEYSTORE_PASSWORD': 'store-pw',
            'ANDROID_KEY_ALIAS': 'release',
            'ANDROID_KEY_PASSWORD': 'key-pw',
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        key_file = self.runner_temp / 'duanju-release.jks'
        self.assertEqual(key_file.read_bytes(), keystore)
        properties = (self.root / 'android' / 'key.properties').read_text()
        self.assertIn('keyAlias=release', properties)

    def test_clean_still_exits_zero(self):
        result = self.run_script({}, args=('--clean',))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_without_runner_temp_refuses(self):
        env = {k: v for k, v in os.environ.items() if k not in SECRET_NAMES}
        env.pop('RUNNER_TEMP', None)
        result = subprocess.run(
            [sys.executable, str(self.script)],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
