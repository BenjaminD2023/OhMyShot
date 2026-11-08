#!/usr/bin/env python3
"""Check public distribution without contacting GitHub or reading private keys.

Run on a mainland connection with VPN/TUN disabled. Disabling HTTP proxies here
cannot disable a system VPN. This is transport/signature QA, not an install test.
"""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from urllib.parse import urljoin, urlsplit

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


class FirstPartyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_url(url):
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or parsed.hostname not in {'ohmyshot.org', 'www.ohmyshot.org'}
            or parsed.port not in {None, 443} or parsed.username or parsed.password):
        raise ValueError(f'Refusing non-website URL: {parsed.scheme}://{parsed.hostname}{parsed.path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/distribution-check')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    # An isolated opener avoids HTTP_PROXY/HTTPS_PROXY and macOS HTTP proxy settings.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), FirstPartyRedirect())
    report = {'time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'network_note': 'HTTP proxies disabled; system VPN/TUN and mainland ISP must be confirmed separately.',
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
        if not re.fullmatch(r'\d+\.\d+\.\d+', version):
            raise ValueError('Invalid release version')
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
        with zipfile.ZipFile(archive) as z:
            plist = plistlib.loads(z.read('OhMyShot.app/Contents/Info.plist'))
        if plist['CFBundleShortVersionString'] != version or str(plist['CFBundleVersion']) != item.findtext(SPARKLE + 'version'):
            raise ValueError('Archive version does not match signed feed')
        result.update(version=version, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                      installed_feed=plist.get('SUFeedURL'))
        report['release'] = result
        if browser_result and hashlib.sha256(browser_zip.read_bytes()).hexdigest() != result['sha256']:
            raise ValueError('Website download and signed update archive differ; retry if a release just changed')
        for flag in ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
            if plist.get(flag) is not True:
                raise ValueError(f'Downloaded app does not enforce {flag}')
        if plist.get('SUPublicEDKey') != public_key:
            raise ValueError('Downloaded app uses a different update public key')
        return result

    release = record('signed feed and complete update archive', update)
    if release:
        def installed_feed():
            if release['installed_feed'] != 'https://www.ohmyshot.org/updates/appcast':
                raise ValueError(f"Downloaded {release['version']} still uses {release['installed_feed']}; publish a newer app before mainland promotion")
            return release['installed_feed']
        record('downloaded app uses the website updater', installed_feed)

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
