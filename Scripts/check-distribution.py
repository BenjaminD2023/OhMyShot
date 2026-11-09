#!/usr/bin/env python3
"""Check public distribution without contacting GitHub or reading private keys.

Run on a mainland connection with VPN/TUN disabled. Disabling HTTP proxies here
cannot disable a system VPN. This is transport/signature QA, not an install test.
"""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import re
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urljoin, urlsplit

ROOT = Path(__file__).resolve().parent.parent
WEBSITE_FEED = 'https://www.ohmyshot.org/updates/appcast'
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
# Load by path so the public checker also works with Python's isolated (-I) mode.
spec = importlib.util.spec_from_file_location('release_updater', ROOT / 'Scripts/check-release-updater.py')
release_updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_updater)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class FirstPartyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_url(url):
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or parsed.hostname not in {'ohmyshot.org', 'www.ohmyshot.org'}
            or parsed.port not in {None, 443} or parsed.username or parsed.password):
        raise ValueError(f'Refusing non-website URL: {parsed.scheme}://{parsed.hostname}{parsed.path}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/distribution-check')
    parser.add_argument('--version', help='Expected latest release version, without v')
    parser.add_argument('--build', help='Expected latest release build number')
    parser.add_argument('--sha256', help='SHA-256 of the original signed CI/local release ZIP')
    args = parser.parse_args(argv)
    expected = (args.version, args.build, args.sha256)
    if any(value is not None for value in expected):
        if not all(expected):
            parser.error('--version, --build and --sha256 must be supplied together')
        if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'[1-9]\d*', args.build):
            parser.error('Expected a three-part version and a positive build number')
        if not re.fullmatch(r'[a-fA-F0-9]{64}', args.sha256):
            parser.error('--sha256 must be a 64-digit hexadecimal digest')
        args.sha256 = args.sha256.lower()
    args.output.mkdir(parents=True, exist_ok=True)
    # An isolated opener avoids HTTP_PROXY/HTTPS_PROXY and macOS HTTP proxy settings.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), FirstPartyRedirect())
    report = {'time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'network_note': 'HTTP proxies disabled; system VPN/TUN and mainland ISP must be confirmed separately.',
              'expected': {'version': args.version, 'build': args.build, 'sha256': args.sha256},
              'checks': []}

    def record(name, fn):
        try:
            detail = fn()
            report['checks'].append({'name': name, 'passed': True, 'detail': detail})
            print(f'PASS {name}: {detail}', flush=True)
            return detail
        except Exception as error:
            report['checks'].append({'name': name, 'passed': False, 'detail': str(error)})
            print(f'FAIL {name}: {error}', flush=True)
            return None

    def get(path, filename=None, headers=None):
        url = urljoin('https://www.ohmyshot.org/', path)
        check_url(url)
        started = time.monotonic()
        req = urllib.request.Request(url, headers={'User-Agent': 'OhMyShot-Distribution-Check', **(headers or {})})
        with opener.open(req, timeout=30) as response:
            check_url(response.url)
            if response.status != (206 if headers and 'Range' in headers else 200):
                raise ValueError(f'Unexpected HTTP status: {response.status}')
            if filename:
                with filename.open('wb') as output:
                    while chunk := response.read(1024 * 1024):
                        output.write(chunk)
                        if time.monotonic() - started > 300:
                            raise TimeoutError('Download exceeded five minutes')
                return {'status': response.status, 'url': response.url, 'bytes': filename.stat().st_size,
                        'seconds': round(time.monotonic() - started, 2)}
            return response.read(), response.headers, response.status

    for path in ['https://ohmyshot.org/', '/', '/zh/']:
        def page(path=path):
            data, _, status = get(path)
            if status != 200 or b'href="/download"' not in data:
                raise ValueError('Page is missing its download link')
            return {'status': status, 'bytes': len(data)}
        record(path, page)
    record('exit-location (diagnostic)', lambda: {
        line.split('=', 1)[0]: line.split('=', 1)[1]
        for line in get('/cdn-cgi/trace')[0].decode().splitlines()
        if line.startswith(('loc=', 'colo=', 'warp='))
    })
    browser_zip = args.output / 'website-download.zip'
    browser_result = record('website download (no external redirects)', lambda: get('/download', browser_zip))
    if browser_result:
        browser_result['sha256'] = sha256(browser_zip)
    verifier = args.output / 'verify-ed25519'
    feed_file = args.output / 'appcast.xml'
    archive = args.output / 'update.zip'

    def update():
        # Anchor verification in the repository's public key, never a key supplied by a downloaded feed.
        public_key = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())['SUPublicEDKey']
        subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Scripts/verify-ed25519.swift'), '-o', str(verifier)], check=True)
        get('/updates/appcast', feed_file)
        feed = feed_file.read_bytes()
        signature = re.search(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: (\d+)\n-->\s*$', feed)
        if not signature or signature.start() != int(signature[2]):
            raise ValueError('Missing or invalid signed feed length')
        signed = args.output / 'appcast-content.xml'
        signed.write_bytes(feed[:signature.start()])
        subprocess.run([str(verifier), public_key, signature[1].decode(), str(signed)], check=True)
        items = ET.fromstring(signed.read_bytes()).findall('channel/item')
        item = max(items, key=lambda i: int(i.findtext(SPARKLE + 'version')))
        version = item.findtext(SPARKLE + 'shortVersionString')
        build = item.findtext(SPARKLE + 'version')
        if not version or not re.fullmatch(r'\d+\.\d+\.\d+', version):
            raise ValueError('Invalid release version')
        if args.version and (version, build) != (args.version, args.build):
            raise ValueError(f'Expected latest {args.version} ({args.build}), found {version} ({build})')
        asset_path = f'/updates/download/v{version}/OhMyShot-{version}.zip'
        enclosure = item.find('enclosure')
        accepted = {f'https://github.com/MMFoundation/OhMyShot/releases/download/v{version}/OhMyShot-{version}.zip',
                    f'https://www.ohmyshot.org{asset_path}'}
        if enclosure.get('url') not in accepted:
            raise ValueError('Appcast archive URL cannot use the app website transport')
        result = get(asset_path, archive)
        if result['bytes'] != int(enclosure.get('length')):
            raise ValueError('Archive length does not match signed feed')
        subprocess.run([str(verifier), public_key, enclosure.get(SPARKLE + 'edSignature'), str(archive)], check=True)
        result.update(version=version, build=build, sha256=sha256(archive))
        report['release'] = result
        if not browser_result:
            raise ValueError('Website download failed; cannot establish archive parity')
        if browser_result['sha256'] != result['sha256']:
            raise ValueError('Website download and signed update archive differ; retry if a release just changed')
        if args.sha256 and result['sha256'] != args.sha256:
            raise ValueError('Public archives do not match the original signed release ZIP SHA-256')
        # One policy for local build, publish, and both publicly downloaded artifacts.
        for artifact in (browser_zip, archive):
            release_updater.check_artifact(artifact, version, build, expected_feed=WEBSITE_FEED)
        result['installed_feed'] = WEBSITE_FEED
        return result

    release = record('signed feed and complete update archive', update)
    if release:
        def byte_range():
            data, headers, status = get(f"/updates/download/v{release['version']}/OhMyShot-{release['version']}.zip", headers={'Range': 'bytes=0-1023'})
            if status != 206 or headers.get('Content-Range') != f"bytes 0-1023/{release['bytes']}" or data != archive.read_bytes()[:1024]:
                raise ValueError('Byte-range response differs from the verified archive')
            return '206, first 1024 bytes match the verified archive'
        record('resumable download', byte_range)
    report['passed'] = all(check['passed'] for check in report['checks'])
    (args.output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"Report: {args.output / 'report.json'}")
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
