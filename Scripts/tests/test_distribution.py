"""Offline public-distribution acceptance tests; never contact a release endpoint."""
import contextlib
import hashlib
import importlib.util
import io
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.request
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('distribution', ROOT / 'Scripts/check-distribution.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class DistributionInputTests(unittest.TestCase):
    def test_rejects_external_and_insecure_redirects(self):
        for url in ['https://github.com/MMFoundation/OhMyShot', 'http://www.ohmyshot.org/download',
                    'https://www.ohmyshot.org.evil.test/', 'https://user@ohmyshot.org/',
                    'https://ohmyshot.org:8443/download']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                checker.FirstPartyRedirect().redirect_request(
                    urllib.request.Request('https://www.ohmyshot.org/download'), None, 302, '', {}, url)
        checker.check_url('https://ohmyshot.org/download')
        checker.check_url('https://www.ohmyshot.org/updates/appcast')

    def test_invalid_or_partial_expectations_stop_before_network_access(self):
        for args in [['--version', '0.2.0'], ['--build', '2'], ['--sha256', 'a' * 64],
                     ['--version', 'v0.2.0', '--build', '2', '--sha256', 'a' * 64],
                     ['--version', '0.2.0', '--build', '0', '--sha256', 'a' * 64],
                     ['--version', '0.2.0', '--build', '2', '--sha256', 'wrong']]:
            with self.subTest(args=args), patch.object(checker.urllib.request, 'build_opener') as opener:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
                    checker.main(args)
                self.assertEqual(result.exception.code, 2)
                opener.assert_not_called()


@unittest.skipUnless(sys.platform == 'darwin', 'Real CryptoKit signature fixtures require macOS')
class DistributionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools_temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tools_temp.cleanup)
        folder = Path(cls.tools_temp.name)
        # A throwaway test-only key; never uses the production private key or Keychain.
        source = folder / 'sign.swift'
        source.write_text('''import CryptoKit
import Foundation
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let result = ["key": key.publicKey.rawRepresentation.base64EncodedString(),
              "signature": try key.signature(for: data).base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''')
        cls.signer = folder / 'sign'
        cls.verifier = folder / 'verify'
        for source, target in [(source, cls.signer), (ROOT / 'Scripts/verify-ed25519.swift', cls.verifier)]:
            subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(target)], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'Config').mkdir()
        self.output = self.root / 'output'
        self.info = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())
        self.info.update(CFBundleIdentifier='io.github.fzlzjerry.ohmyshot',
                         CFBundleShortVersionString='0.2.0', CFBundleVersion='2',
                         SUFeedURL=checker.release_updater.WEBSITE_FEED,
                         SUPublicEDKey=self.sign(b'')['key'])
        (self.root / 'Config/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.archive = self.make_zip()
        self.browser = self.archive
        self.feed = self.make_feed()
        self.expected_hash = hashlib.sha256(self.archive).hexdigest()
        self.download_status = 200
        self.bad_range = False
        self.requested = []

    def sign(self, content):
        path = self.root / 'to-sign'
        path.write_bytes(content)
        return json.loads(subprocess.check_output([str(self.signer), str(path)]))

    def make_zip(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('OhMyShot.app/Contents/Info.plist', plistlib.dumps(self.info))
            archive.writestr('fixture-padding', b'x' * 2048)
        return data.getvalue()

    def make_feed(self, version='0.2.0', build='2', length=None, archive_signature=None):
        archive_signature = archive_signature or self.sign(self.archive)['signature']
        content = f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
<enclosure url="https://github.com/MMFoundation/OhMyShot/releases/download/v{version}/OhMyShot-{version}.zip"
length="{len(self.archive) if length is None else length}" sparkle:edSignature="{archive_signature}"/>
</item></channel></rss>
'''.encode()
        signature = self.sign(content)['signature']
        return content + f'<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n'.encode()

    def open(self, request, timeout):
        url = request.full_url
        self.requested.append(url)
        checker.check_url(url)
        path = checker.urlsplit(url).path
        headers, status = {}, 200
        if path in ['/', '/zh/']:
            data = b'<a href="/download">Download</a>'
        elif path == '/cdn-cgi/trace':
            data = b'loc=US\ncolo=SJC\nwarp=off\n'
        elif path == '/download':
            data, status = self.browser, self.download_status
        elif path == '/updates/appcast':
            data = self.feed
        elif path == '/updates/download/v0.2.0/OhMyShot-0.2.0.zip':
            data = self.archive
            if request.get_header('Range'):
                data, status = data[:1024], 206
                headers['Content-Range'] = f'bytes 0-1023/{len(self.archive)}'
                if self.bad_range:
                    data = b'wrong'
        else:
            raise AssertionError(f'Unexpected request: {url}')
        response = io.BytesIO(data)
        response.url, response.headers, response.status = url, headers, status
        return response

    def run_check(self, expected=True):
        args = ['--output', str(self.output)]
        if expected:
            args += ['--version', '0.2.0', '--build', '2', '--sha256', self.expected_hash]
        run = subprocess.run

        def verify(command, **kwargs):
            if command[:2] == ['xcrun', 'swiftc']:
                # Compile once per suite; execute the real verifier for every signature check.
                shutil.copyfile(self.verifier, command[-1])
                Path(command[-1]).chmod(0o755)
                return subprocess.CompletedProcess(command, 0)
            return run(command, **kwargs, capture_output=True)

        with patch.object(checker, 'ROOT', self.root), patch.object(checker.release_updater, 'ROOT', self.root), \
             patch.object(checker.urllib.request, 'build_opener') as factory, \
             patch.object(checker.subprocess, 'run', side_effect=verify), contextlib.redirect_stdout(io.StringIO()):
            factory.return_value.open.side_effect = self.open
            result = checker.main(args)
        report = json.loads((self.output / 'report.json').read_text())
        self.assertEqual(report['passed'], result == 0)
        return result, report

    def assert_failure(self, reason):
        result, report = self.run_check()
        self.assertEqual(result, 1)
        failures = '\n'.join(check['detail'] for check in report['checks'] if not check['passed'])
        self.assertIn(reason, failures)

    def test_verifies_signed_identical_archives_and_records_release_evidence(self):
        result, report = self.run_check()
        self.assertEqual(result, 0)
        self.assertEqual(report['expected'], {'version': '0.2.0', 'build': '2', 'sha256': self.expected_hash})
        self.assertEqual(report['release']['sha256'], self.expected_hash)
        self.assertEqual(report['release']['build'], '2')
        self.assertEqual(report['release']['installed_feed'], checker.release_updater.WEBSITE_FEED)
        self.assertIn('https://www.ohmyshot.org/download', self.requested)
        self.assertEqual(self.run_check(expected=False)[0], 0) # Mainland diagnostic mode remains available.

    def test_rejects_stale_or_unexpected_signed_feed(self):
        for version, build in [('0.1.0', '1'), ('0.2.0', '3'), ('0.3.0', '3')]:
            with self.subTest(version=version, build=build):
                self.feed = self.make_feed(version=version, build=build)
                self.assert_failure('Expected latest')

    def test_rejects_browser_and_update_archive_mismatch(self):
        self.browser += b'different bytes'
        self.assert_failure('Website download and signed update archive differ')

    def test_rejects_matching_archives_from_the_wrong_build_artifact(self):
        self.expected_hash = '0' * 64
        self.assert_failure('original signed release ZIP SHA-256')

    def test_rejects_partial_website_download(self):
        self.download_status = 206
        self.assert_failure('Unexpected HTTP status')

    def test_rejects_tampered_feed_and_archive_signatures(self):
        self.feed = self.feed.replace(b'<channel>', b'<channel> ')
        self.assert_failure('signed feed length')
        self.feed = self.make_feed().replace(b'<channel>', b'<channeL>') # Same length, invalid signature.
        self.assert_failure('returned non-zero exit status')
        self.archive += b'tamper'
        self.feed = self.make_feed(archive_signature=self.sign(b'wrong archive')['signature'])
        self.assert_failure('returned non-zero exit status')

    def test_rejects_signed_archive_length_mismatch(self):
        self.feed = self.make_feed(length=len(self.archive) + 1)
        self.assert_failure('Archive length does not match')

    def test_rejects_legacy_or_weakened_updater_in_signed_matching_archives(self):
        for key, value in [('SUFeedURL', 'https://github.com/legacy/appcast.xml'),
                           ('SUSignedFeedFailureExpirationInterval', 3600),
                           ('SURequireSignedFeed', False), ('SUVerifyUpdateBeforeExtraction', False),
                           ('SUPublicEDKey', 'wrong'), ('CFBundleVersion', '1'),
                           ('CFBundleIdentifier', 'io.github.fzlzjerry.ohmyshot.dev')]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.archive = self.browser = self.make_zip()
                self.feed = self.make_feed()
                self.expected_hash = hashlib.sha256(self.archive).hexdigest()
                self.assert_failure(key)
                self.info[key] = original

    def test_rejects_incorrect_range_bytes(self):
        self.bad_range = True
        self.assert_failure('Byte-range response differs')

    def test_retry_does_not_reuse_a_previous_passing_report(self):
        self.assertEqual(self.run_check()[0], 0)
        self.browser += b'stale download'
        self.assert_failure('Website download and signed update archive differ')
