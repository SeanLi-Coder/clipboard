#!/bin/bash
set -euo pipefail

# Exercise Sparkle's official updater against disposable, ad-hoc-signed fixtures.
# The fixture links ClipboardCore but only opens a named pasteboard and a temp directory.
# Official CLI API: https://sparkle-project.org/documentation/sparkle-cli/
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/ClipShelf.app"
APP_ARGUMENT_SEEN=0
KEEP_TEMP=""
for argument in "$@"; do
  case "$argument" in
    --keep-temp) KEEP_TEMP="--keep-temp" ;;
    -*) echo "Usage: scripts/verify-update.sh [path/to/ClipShelf.app] [--keep-temp]" >&2; exit 2 ;;
    *)
      if [[ "$APP_ARGUMENT_SEEN" -eq 1 ]]; then
        echo "Usage: scripts/verify-update.sh [path/to/ClipShelf.app] [--keep-temp]" >&2
        exit 2
      fi
      APP_PATH="$argument"
      APP_ARGUMENT_SEEN=1
      ;;
  esac
done
if [[ "$(/usr/bin/uname -s)" != "Darwin" || "$(/usr/bin/uname -m)" != "arm64" ]]; then
  echo "Update verification requires an Apple Silicon Mac and an active login session." >&2
  exit 2
fi
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Build the app first with scripts/build.sh." >&2
  exit 2
fi
SPARKLE_FRAMEWORK="$(cd "$SPARKLE_FRAMEWORK" && pwd)"
SPARKLE_BIN="$("$PROJECT_DIR/scripts/download-sparkle-tools.sh")"
/usr/bin/python3 - "$PROJECT_DIR" "$SPARKLE_FRAMEWORK" "$SPARKLE_BIN" "$KEEP_TEMP" <<'PY'
import base64
import concurrent.futures
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
import xml.etree.ElementTree as ET

project, original_framework, tool_bin = map(Path, sys.argv[1:4])
keep_temp = sys.argv[4] == '--keep-temp'
work = Path(tempfile.mkdtemp(prefix='clipshelf-update-check.'))
os.chmod(work, 0o700)
fixture_id = 'com.seanli.clipshelf.update-fixture.' + uuid.uuid4().hex
cli_id = fixture_id + '.cli'
data_dir = work / 'SyntheticHistory'
site = work / 'site'
installed = work / 'Installed' / 'UpdateFixture.app'
updated = work / 'Payload' / 'UpdateFixture.app'
cli = work / 'Verifier.app'
server = None
succeeded = False
requests = []
signer = tool_bin / 'sign_update'

def run(command, expected=0, timeout=60, log=None):
    result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    if log is not None:
        (work / log).write_text(result.stdout)
    if result.returncode != expected:
        raise RuntimeError(f'Command failed ({result.returncode}, expected {expected}): {command[0]}\n{result.stdout}')
    return result.stdout

def wait_for(predicate, message, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise RuntimeError(message)

def load_launches():
    launch_file = data_dir / 'launches.jsonl'
    if not launch_file.exists():
        return []
    return [json.loads(line) for line in launch_file.read_text().splitlines() if line]

def info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())

def sign_bundle(app):
    run(['/usr/bin/codesign', '--force', '--sign', '-', app], log=app.stem + '-codesign.log')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])

def sign_file(path):
    return run([signer, '--ed-key-file', work / 'ephemeral-key.txt', '-p', path]).strip()

try:
    print('Preparing isolated Sparkle 2.10.0 update fixtures...', flush=True)
    for directory in [data_dir, site, installed / 'Contents/MacOS', updated.parent, cli / 'Contents/MacOS', cli / 'Contents/Frameworks']:
        directory.mkdir(parents=True, exist_ok=True)
    run(['/usr/bin/ditto', original_framework, cli / 'Contents/Frameworks/Sparkle.framework'])
    framework = cli / 'Contents/Frameworks/Sparkle.framework'
    framework_info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    if framework_info['CFBundleShortVersionString'] != '2.10.0':
        raise RuntimeError('The verification script is pinned to Sparkle 2.10.0.')

    # Sparkle 2.9+ stopped shipping the CLI binary. Build its unchanged official source.
    source_dir = work / 'official-cli-source'
    source_dir.mkdir()
    source_hashes = {
        'Info.plist': '0d04f5392050cf6ecd2f50ea7c06799f77878328ca3838fc707a4439cb17b852',
        'LICENSE': '389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe',
        'SPUCommandLineDriver.h': '3f7d8efdd5b1be0e150ecb75795e70b0cd4fadbd1b18818b2dcf7c26f0dd6171',
        'SPUCommandLineDriver.m': '0924b26df77f726afafed2bb149998c4c27813574c0a9e67ddf69cc0419490b1',
        'SPUCommandLineUserDriver.h': '525cc91b76b7c88d3f0bc476cfdf0df72c50739c31d3ff71e9da9a6bb4773c42',
        'SPUCommandLineUserDriver.m': '7e23c34763c74afbdbb7095cdd02d23343e9d0836e358e9da1099ff198e51600',
        'main.m': '6df90a46bc481a76261f1b5c1a3123572f316fa3dc4463ab4269e2f5ecd0051e',
    }
    def fetch_source(name):
        relative = name if name == 'LICENSE' else 'sparkle-cli/' + name
        url = 'https://raw.githubusercontent.com/sparkle-project/Sparkle/eef1a539a373c1f1a320624b1130fc5de7b2e100/' + relative
        contents = urllib.request.urlopen(url, timeout=30).read()
        if hashlib.sha256(contents).hexdigest() != source_hashes[name]:
            raise RuntimeError('Official Sparkle CLI source checksum mismatch: ' + name)
        (source_dir / name).write_bytes(contents)
    with concurrent.futures.ThreadPoolExecutor(max_workers=7) as pool:
        list(pool.map(fetch_source, source_hashes))

    cli_info = plistlib.loads((source_dir / 'Info.plist').read_bytes())
    cli_info.update(CFBundleExecutable='sparkle', CFBundleIdentifier=cli_id,
                    CFBundleName='ClipShelf Update Verifier', CFBundleShortVersionString='2.10.0',
                    CFBundleVersion='21000', LSMinimumSystemVersion='13.0')
    (cli / 'Contents/Info.plist').write_bytes(plistlib.dumps(cli_info))
    cli_binary = cli / 'Contents/MacOS/sparkle'
    run(['/usr/bin/xcrun', 'clang', '-fobjc-arc', '-fblocks', '-arch', 'arm64', '-mmacosx-version-min=13.0',
         '-DSPU_OBJC_DIRECT=__attribute__((objc_direct))', '-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))',
         '-F', framework.parent, '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'Sparkle',
         source_dir / 'main.m', source_dir / 'SPUCommandLineDriver.m', source_dir / 'SPUCommandLineUserDriver.m',
         '-Wl,-rpath,@executable_path/../Frameworks', '-o', cli_binary], log='compile-cli.log')
    sign_bundle(cli)

    keygen = work / 'make-key.swift'
    keygen.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: output)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
    public_key = run(['/usr/bin/xcrun', 'swift', keygen, work / 'ephemeral-key.txt']).strip()
    fixture_source = work / 'UpdateFixture.swift'
    fixture_source.write_text(r'''import AppKit
import Foundation

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var store: HistoryStore?
    private var timer: Timer?
    private var dataDirectory: URL!
    private var pasteboard: NSPasteboard!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let path = Bundle.main.object(forInfoDictionaryKey: "FixtureDataDirectory") as! String
            dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
            pasteboard = NSPasteboard(name: .init(Bundle.main.bundleIdentifier!))
            let history = HistoryStore(directory: dataDirectory, pasteboard: pasteboard)
            store = history
            if history.entries.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString("Synthetic update verification history", forType: .string)
                history.captureNow()
                history.flushPendingWrites()
            }
            guard history.entries.count == 1,
                  history.entries[0].text == "Synthetic update verification history" else {
                throw NSError(domain: "Fixture", code: 1)
            }
            let record: [String: Any] = [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")!,
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")!,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "historyID": history.entries[0].id.uuidString
            ]
            let log = dataDirectory.appendingPathComponent("launches.jsonl")
            var contents = (try? Data(contentsOf: log)) ?? Data()
            contents.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
            contents.append(Data("\n".utf8))
            try contents.write(to: log, options: .atomic)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if FileManager.default.fileExists(atPath: self.dataDirectory.appendingPathComponent("stop").path) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        } catch {
            fputs("Fixture initialization failed\n", stderr)
            exit(1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        store?.stopMonitoring()
        pasteboard?.releaseGlobally()
    }
}

@main
struct FixtureApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.setActivationPolicy(.prohibited)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
''')
    run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macos13.0',
         '-parse-as-library', *sorted((project / 'Sources/ClipboardCore').glob('*.swift')), fixture_source,
         '-o', installed / 'Contents/MacOS/UpdateFixture'], log='compile-fixture.log')
    fixture_info = dict(CFBundleIdentifier=fixture_id, CFBundleName='UpdateFixture',
                        CFBundleExecutable='UpdateFixture', CFBundlePackageType='APPL',
                        CFBundleInfoDictionaryVersion='6.0', CFBundleShortVersionString='1.0.9',
                        CFBundleVersion='10009', LSMinimumSystemVersion='13.0', LSUIElement=True,
                        SUPublicEDKey=public_key, SUVerifyUpdateBeforeExtraction=True,
                        SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0,
                        SUEnableAutomaticChecks=False, FixtureDataDirectory=str(data_dir))
    (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps(fixture_info))
    run(['/usr/bin/ditto', framework, installed / 'Contents/Frameworks/Sparkle.framework'])
    sign_bundle(installed)
    run(['/usr/bin/ditto', installed, updated])
    fixture_info.update(CFBundleVersion='10100', CFBundleShortVersionString='1.1.0')
    (updated / 'Contents/Info.plist').write_bytes(plistlib.dumps(fixture_info))
    sign_bundle(updated)
    archive = site / 'update.zip'
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', updated, archive])
    signature = sign_file(archive)
    run([signer, '--verify', '--ed-key-file', work / 'ephemeral-key.txt', archive, signature])

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, message, *args):
            requests.append(self.path)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(site)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = 'http://127.0.0.1:' + str(server.server_address[1])
    sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    ET.register_namespace('sparkle', sparkle)
    def make_feed(name, build, version, archive_signature):
        rss = ET.Element('rss', version='2.0')
        channel = ET.SubElement(rss, 'channel')
        ET.SubElement(channel, 'title').text = 'ClipShelf synthetic update verification'
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, 'title').text = 'Synthetic update ' + version
        ET.SubElement(item, '{' + sparkle + '}version').text = build
        ET.SubElement(item, '{' + sparkle + '}shortVersionString').text = version
        ET.SubElement(item, '{' + sparkle + '}minimumSystemVersion').text = '13.0'
        ET.SubElement(item, 'enclosure', url=base_url + '/update.zip', length=str(archive.stat().st_size),
                      type='application/octet-stream', **{'{' + sparkle + '}edSignature': archive_signature})
        feed = site / name
        ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
        sign_file(feed)
        return base_url + '/' + name
    newer = make_feed('newer.xml', '10100', '1.1.0', signature)
    same = make_feed('same.xml', '10009', '1.0.9', signature)
    older = make_feed('older.xml', '10008', '1.0.8', signature)
    wrong = make_feed('wrong-archive-signature.xml', '10100', '1.1.0', base64.b64encode(bytes(64)).decode())
    invalid_feed = site / 'wrong-feed-signature.xml'
    invalid_feed.write_bytes((site / 'newer.xml').read_bytes().replace(b'Synthetic update 1.1.0', b'Synthetic update 1.1.X'))

    def check(feed, expected, name, probe=False):
        command = [cli_binary, installed, '--feed-url', feed,
                   '--user-agent-name', 'ClipShelf isolated update verification', '--verbose']
        if probe:
            command.append('--probe')
        else:
            command.append('--check-immediately')
        return run(command, expected=expected, timeout=55, log=name + '.log')

    print('Checking newer, equal, and older build comparison...', flush=True)
    check(newer, 0, 'probe-newer', probe=True)
    check(same, 4, 'probe-same', probe=True)
    check(older, 4, 'probe-older', probe=True)
    print('Checking invalid signed feed rejection...', flush=True)
    feed_result = check(base_url + '/wrong-feed-signature.xml', 1, 'reject-feed')
    if 'error 1000 (SUSparkleErrorDomain)' not in feed_result or 'improperly signed' not in feed_result:
        raise RuntimeError('Invalid feed failed for a reason other than signature validation; inspect reject-feed.log.')
    if '/update.zip' in requests:
        raise RuntimeError('A rejected feed unexpectedly downloaded an update archive.')
    print('Checking invalid archive signature rejection...', flush=True)
    archive_result = check(wrong, 1, 'reject-archive')
    if 'error 4005 (SUSparkleErrorDomain)' not in archive_result or 'improperly signed' not in archive_result:
        raise RuntimeError('Invalid archive failed for a reason other than signature validation; inspect reject-archive.log.')
    if '/update.zip' not in requests or info(installed)['CFBundleVersion'] != '10009':
        raise RuntimeError('Invalid update was not downloaded and rejected without replacing the app.')

    print('Launching the old fixture with synthetic history...', flush=True)
    run(['/usr/bin/open', '-n', '-g', installed])
    wait_for(lambda: len(load_launches()) == 1, 'The old fixture did not launch.')
    original_launch = load_launches()[0]
    history_bytes = (data_dir / 'history.plist').read_bytes()
    print('Installing 1.1.0 (10100) over 1.0.9 (10009) with the official updater...', flush=True)
    check(newer, 0, 'install-update')
    wait_for(lambda: any(record['build'] == '10100' for record in load_launches()), 'The updated fixture was not relaunched.')
    updated_launch = [record for record in load_launches() if record['build'] == '10100'][-1]
    invariants = [
        (info(installed)['CFBundleVersion'] == '10100', 'The installed bundle was not replaced.'),
        (original_launch['pid'] != updated_launch['pid'], 'The new executable was not relaunched.'),
        (original_launch['historyID'] == updated_launch['historyID'], 'The history record ID changed.'),
        ((data_dir / 'history.plist').read_bytes() == history_bytes, 'The history bytes changed during update.'),
    ]
    for valid, failure in invariants:
        if not valid:
            raise RuntimeError(failure)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', installed])
    check(newer, 4, 'probe-after-update', probe=True)
    check(older, 4, 'probe-downgrade', probe=True)
    result = dict(sparkle='2.10.0', fromVersion='1.0.9', toVersion='1.1.0',
                  oldPID=original_launch['pid'], newPID=updated_launch['pid'],
                  historySHA256=hashlib.sha256(history_bytes).hexdigest(),
                  checks=['newer-found', 'equal-rejected', 'older-rejected', 'invalid-feed-rejected',
                          'invalid-archive-rejected', 'bundle-replaced', 'app-relaunched',
                          'history-bytes-preserved', 'history-entry-reloaded', 'updated-signature-valid',
                          'no-reinstall', 'no-downgrade'])
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: signed feed/archive validation, version selection, ad-hoc installation, restart, and history preservation.', flush=True)
    print('Scope: temporary fixture using production ClipboardCore and Sparkle; the product UI and Gatekeeper first-install flow are not exercised.', flush=True)
    succeeded = True
finally:
    # This stop marker is watched only by the disposable fixture application.
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / 'stop').touch()
    fixture_pids = {record['pid'] for record in load_launches()}
    def fixture_running():
        for pid in fixture_pids:
            command = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'comm='], text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
            if command == str(installed / 'Contents/MacOS/UpdateFixture'):
                return True
        return False
    stop_deadline = time.monotonic() + 5
    while fixture_running() and time.monotonic() < stop_deadline:
        time.sleep(0.1)
    stopped = not fixture_running()
    if server is not None:
        server.shutdown()
        server.server_close()
    registration_tool = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
    if registration_tool.exists():
        for bundle in [installed, updated, cli]:
            subprocess.run([str(registration_tool), '-u', str(bundle)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for domain in [fixture_id, cli_id]:
        subprocess.run(['/usr/bin/defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cache = Path.home() / 'Library/Caches' / domain
        if cache.exists():
            shutil.rmtree(cache)
    if succeeded and stopped and not keep_temp:
        shutil.rmtree(work)
    else:
        # Ephemeral signing keys are removed even when diagnostic artifacts are kept.
        (work / 'ephemeral-key.txt').unlink(missing_ok=True)
        print('Verification artifacts: ' + str(work), flush=True)
    if not stopped:
        raise RuntimeError('The disposable fixture did not stop; its files were retained for inspection.')
PY
