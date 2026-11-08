import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_updater', ROOT / 'Scripts/check-release-updater.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ReleaseUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'OhMyShot.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.info = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())
        self.info.update(CFBundleIdentifier='io.github.fzlzjerry.ohmyshot',
                         CFBundleShortVersionString='0.2.0', CFBundleVersion='2', SUFeedURL=checker.WEBSITE_FEED)

    def write_app(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        return self.app

    def write_archive(self):
        archive = self.root / 'OhMyShot-0.2.0.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('OhMyShot.app/Contents/Info.plist', plistlib.dumps(self.info))
        return archive

    def test_accepts_built_app_and_final_archive(self):
        for artifact in [self.write_app(), self.write_archive()]:
            checker.check_artifact(artifact, '0.2.0', '2')

    def test_rejects_upstream_feed_in_both_artifacts(self):
        self.info['SUFeedURL'] = 'https://github.com/MMFoundation/OhMyShot/releases/latest/download/appcast.xml'
        for artifact in [self.write_app(), self.write_archive()]:
            with self.assertRaisesRegex(ValueError, 'SUFeedURL'):
                checker.check_artifact(artifact, '0.2.0', '2')

    def test_rejects_missing_or_weakened_verification(self):
        for key, bad in [('SURequireSignedFeed', False), ('SUVerifyUpdateBeforeExtraction', False),
                         ('SUSignedFeedFailureExpirationInterval', 3600), ('SUPublicEDKey', 'another-key'),
                         ('SURequireSignedFeed', 'true')]:
            with self.subTest(key=key, bad=bad):
                original = self.info[key]
                self.info[key] = bad
                with self.assertRaisesRegex(ValueError, key):
                    checker.check_artifact(self.write_app(), '0.2.0', '2')
                del self.info[key]
                with self.assertRaisesRegex(ValueError, key):
                    checker.check_artifact(self.write_archive(), '0.2.0', '2')
                self.info[key] = original

    def test_rejects_wrong_version_build_and_debug_app(self):
        for key, bad in [('CFBundleShortVersionString', '0.1.0'), ('CFBundleVersion', '1'),
                         ('CFBundleIdentifier', 'io.github.fzlzjerry.ohmyshot.dev'), ('SUFeedURL', '')]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = bad
                with self.assertRaisesRegex(ValueError, key):
                    checker.check_artifact(self.write_archive(), '0.2.0', '2')
                self.info[key] = original

    def test_rejects_archive_without_the_app(self):
        archive = self.root / 'bad.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('README', 'not the application')
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            checker.check_artifact(archive, '0.2.0', '2')
