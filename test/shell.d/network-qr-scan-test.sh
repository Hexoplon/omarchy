#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
require_command qrencode
require_command zbarimg
require_command setpriv

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Stands in for the camera. ZBAR_MODE picks what the preview "saw"; each call
# records its argv and PID so the decoder flags and shutdown can be checked.
cat >"$tmp/bin/zbarcam" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$ZBAR_ARGS"
printf '%s\n' "$$" >"$ZBAR_PID"
case $ZBAR_MODE in
  payload) printf '%s' "$ZBAR_PAYLOAD" ;;
  closed) ;;
  busy) exit 1 ;;
  latin1) printf 'WIFI:S:Caf\xe9;;' ;;
  hang) sleep 30 & wait ;;
esac
EOF
chmod +x "$tmp/bin/zbarcam"

export HELPER="$ROOT/bin/omarchy-network-qr-scan"
export PATH="$tmp/bin:$PATH"
export ZBAR_ARGS="$tmp/zbar-args" ZBAR_PID="$tmp/zbar-pid"

# The helper loads as a module so its pieces run without a camera or a live
# NetworkManager. Assertions speak the same protocol as the bash ones.
run_python_test() {
  {
    cat <<'PY_PRELUDE'
import contextlib, importlib.machinery, importlib.util, io, json, os, subprocess, sys
from unittest.mock import Mock, patch

loader = importlib.machinery.SourceFileLoader("qr_scan", os.environ["HELPER"])
spec = importlib.util.spec_from_loader(loader.name, loader)
qr = importlib.util.module_from_spec(spec)
loader.exec_module(qr)
NM, GLib = qr.NM, qr.GLib


def check(condition, description, detail=""):
    if not condition:
        if detail:
            print(detail, file=sys.stderr)
        print(f"not ok - {description}", file=sys.stderr)
        sys.exit(1)
    print(f"ok - {description}", flush=True)


def check_equal(actual, expected, description):
    check(actual == expected, description, f"expected: {expected!r}\nactual:   {actual!r}")


def raises(fn, *args):
    try:
        fn(*args)
    except qr.WifiError as error:
        return str(error)
    return ""
PY_PRELUDE
    cat
  } | python3 -
}

run_python_test <<'PY'
# ZBar decodes the camera frames, so pin the bytes it hands over for a code
# full of escapes, Unicode, and edge whitespace. zbarimg ends each result with
# a newline that zbarcam --oneshot --raw does not write.
payload = 'WIFI:T:WPA;S:Café\\; 日本;P: a\\;b\\:c\\,d\\\\e"f\n ;;'
image = subprocess.run(["qrencode", "-o", "-"], input=payload.encode(), capture_output=True, check=True).stdout
decoded = subprocess.run(
    ["zbarimg", "--quiet", "--nodbus", "--raw", "-Sdisable", "-Sqrcode.enable", "-Sqrcode.binary", "-"],
    input=image, capture_output=True, check=True,
).stdout
check_equal(decoded, payload.encode() + b"\n", "ZBar returns the Wi-Fi code's exact bytes")

code = qr.parse_wifi(decoded[:-1].decode())
check_equal((code.ssid, code.password), ("Café; 日本", ' a;b:c,d\\e"f\n '), "escaped delimiters and edge whitespace survive parsing")
check_equal((code.security, code.hidden), ("WPA", False), "a code reports its security and visibility")

# omarchy-network-qr's own share format, open-network form included.
code = qr.parse_wifi("WIFI:T:nopass;S:Cafe Open;P:;;")
check_equal((code.security, code.password), ("NOPASS", ""), "an open code from the share card parses")
check_equal(qr.parse_wifi("WIFI:S:Lab;;").security, "NOPASS", "a code without T: is an open network")
check(qr.parse_wifi("WIFI:S:Lab;T:SAE;P:x;H:true;;").hidden, "H:true marks a hidden network")

for payload in [
    "https://example.com", "DPP:K:example;;", "WIFI:T:WPA2-EAP;S:test;;", "WIFI:S:test;T:WPA;P:short;;",
    "WIFI:S:test;S:other;;", "WIFI:S:" + "é" * 17 + ";;", "WIFI:S:test;H:yes;;", "WIFI:S:test\\",
    "WIFI:S:test;P:unfinished", "WIFI:T:WPA;P:password;;", "WIFI:S:test;T:WEP;;",
]:
    check(raises(qr.parse_wifi, payload), f"rejects {payload!r}")
PY

run_python_test <<'PY'
def scan_with(mode, payload=""):
    os.environ["ZBAR_MODE"], os.environ["ZBAR_PAYLOAD"] = mode, payload
    return qr.scan("/dev/video7")

code = scan_with("payload", "WIFI:T:WPA;S:Lab;P:pass word ;;")
check_equal(code.password, "pass word ", "a scan keeps the password's trailing space")
args = open(os.environ["ZBAR_ARGS"]).read().split()
for flag in ("--nodbus", "--raw", "--oneshot", "-Sdisable", "-Sqrcode.enable", "-Sqrcode.binary"):
    check(flag in args, f"zbarcam runs with {flag}")
check_equal(args[-1], "/dev/video7", "zbarcam opens the chosen camera")

check(scan_with("closed") is None, "closing the preview cancels the scan")
check("Close other camera apps" in raises(scan_with, "busy"), "a camera failure explains itself")
check("not a Wi-Fi QR" in raises(scan_with, "payload", "otpauth://totp/x"), "a non-Wi-Fi code asks for a Wi-Fi one")
check("text encoding" in raises(scan_with, "latin1"), "a code that is not UTF-8 is refused")

# A preview nobody points a code at must not hold the camera forever.
qr.SCAN_TIMEOUT_SEC = 1
check("No QR code detected" in raises(scan_with, "hang"), "a scan with nothing in view times out")
pid = int(open(os.environ["ZBAR_PID"]).read())
check(not os.path.exists(f"/proc/{pid}"), "a timed-out scan stops the preview")
PY

# Quickshell SIGKILLs the helper when the panel is destroyed, as a bar reload
# does. Nothing in the helper runs then, so the kernel has to stop the preview.
rm -f "$ZBAR_PID"
ZBAR_MODE=hang python3 - >/dev/null 2>&1 <<'PY' &
import importlib.machinery, importlib.util, os
loader = importlib.machinery.SourceFileLoader("qr_scan", os.environ["HELPER"])
spec = importlib.util.spec_from_loader(loader.name, loader)
qr = importlib.util.module_from_spec(spec)
loader.exec_module(qr)
qr.scan("/dev/video7")
PY
helper=$!
for _ in {1..50}; do
  [[ -s $ZBAR_PID ]] && break
  sleep 0.1
done
[[ -s $ZBAR_PID ]] || fail "the scan starts the preview"
zbar_pid=$(<"$ZBAR_PID")
kill -KILL "$helper"
wait "$helper" 2>/dev/null || true
for _ in {1..30}; do
  kill -0 "$zbar_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$zbar_pid" 2>/dev/null; then
  kill -KILL "$zbar_pid"
  fail "a killed helper takes the camera preview down with it"
fi
pass "a killed helper takes the camera preview down with it"

run_python_test <<'PY'
def ssid(connection):
    return bytes(connection.get_setting_wireless().get_ssid().get_data())

for security, password in [("nopass", ""), ("WPA", "password"), ("WPA2", "a" * 64), ("SAE", "x"), ("WPA3", "x"), ("WEP", "abcde")]:
    connection = qr.build_connection(qr.parse_wifi(f"WIFI:S:test;T:{security};P:{password};H:true;;"))
    check(connection.verify() and connection.verify_secrets(), f"a new {security} profile is valid")
    check(connection.get_setting_wireless().get_hidden() and ssid(connection) == b"test", f"a new {security} profile keeps the SSID and hidden flag")

key_mgmt = lambda code: qr.build_connection(qr.parse_wifi(code)).get_setting_wireless_security().get_key_mgmt()
check_equal(key_mgmt("WIFI:S:t;T:WPA;P:password;;"), "wpa-psk", "WPA codes join as wpa-psk, which also covers WPA3 transition")
check_equal(key_mgmt("WIFI:S:t;T:SAE;P:x;;"), "sae", "SAE codes join as WPA3")
check(qr.build_connection(qr.parse_wifi("WIFI:S:t;;")).get_setting_wireless_security() is None, "open codes carry no security setting")

# A saved profile keeps everything but the credential: UUID, band, DNS, PMF,
# its WPA3-only choice, and hidden, which phones leave out of their codes.
old = qr.build_connection(qr.parse_wifi("WIFI:S:test;T:SAE;P:old-password;H:true;;"))
old.get_setting_wireless().props.band = "a"
old.get_setting_wireless_security().props.pmf = NM.SettingWirelessSecurityPmf.REQUIRED
old.get_setting_ip4_config().props.ignore_auto_dns = True
old.get_setting_ip4_config().add_dns("1.1.1.1")
new = qr.build_connection(qr.parse_wifi("WIFI:S:test;T:WPA;P:new-password;;"), old)
check_equal(new.get_uuid(), old.get_uuid(), "an updated profile keeps its UUID")
check_equal(new.get_setting_wireless().get_band(), "a", "an updated profile keeps its band")
check_equal(new.get_setting_ip4_config().get_dns(0), "1.1.1.1", "an updated profile keeps its DNS")
check(new.get_setting_wireless().get_hidden(), "a code without H: does not un-hide a saved profile")
security = new.get_setting_wireless_security()
check_equal(security.get_key_mgmt(), "sae", "a generic WPA code keeps a saved WPA3-only profile")
check_equal(security.get_pmf(), NM.SettingWirelessSecurityPmf.REQUIRED, "an updated profile keeps PMF")
check_equal((security.get_psk(), security.get_psk_flags()), ("new-password", NM.SettingSecretFlags.NONE), "an updated profile stores the new password")
check_equal(old.get_setting_wireless_security().get_psk(), "old-password", "the saved profile is cloned, not edited in place")

old_wep = qr.build_connection(qr.parse_wifi("WIFI:S:old;T:WEP;P:abcde;;"))
old_wep.get_setting_wireless_security().props.wep_tx_keyidx = 2
new_wep = qr.build_connection(qr.parse_wifi("WIFI:S:old;T:WEP;P:fghij;;"), old_wep)
check_equal(
    (new_wep.get_setting_wireless_security().get_wep_key(0), new_wep.get_setting_wireless_security().get_wep_tx_keyidx()),
    ("fghij", 0), "a WEP update transmits with the key it just stored",
)

# Profile choice: same SSID bytes, a compatible security family, usable on
# this adapter, never enterprise; the most recently used one wins.
def profile(code, timestamp, enterprise=False):
    connection = qr.build_connection(qr.parse_wifi(code))
    connection.get_setting_connection().props.timestamp = timestamp
    if enterprise:
        connection.add_setting(NM.Setting8021x.new())
    return connection

older = profile("WIFI:S:Lab;T:WPA;P:password;;", 100)
newer = profile("WIFI:S:Lab;T:SAE;P:password;;", 200)
other_adapter = profile("WIFI:S:Lab;T:WPA;P:password;;", 300)
candidates = [
    older, newer, other_adapter,
    profile("WIFI:S:Lab;T:WPA;P:password;;", 400, enterprise=True),
    profile("WIFI:S:Lab;;", 500),
    profile("WIFI:S:Lab 5G;T:WPA;P:password;;", 600),
]
client, device = Mock(), Mock()
client.get_connections.return_value = candidates

def compatible(connection):
    if connection is other_adapter:
        raise GLib.Error("bound to another adapter")
    return True
device.connection_compatible.side_effect = compatible

code = qr.parse_wifi("WIFI:S:Lab;T:WPA;P:password;;")
check(qr.saved_profile(client, device, code) is newer, "the most recent compatible profile on this adapter is updated")
check(qr.saved_profile(client, device, qr.parse_wifi("WIFI:S:Lab;T:WPA;P:" + "a" * 64 + ";;")) is older,
      "a raw hex key never lands in a WPA3-only profile")
check(qr.saved_profile(client, device, qr.parse_wifi("WIFI:S:Elsewhere;;")) is None, "an unknown network gets a new profile")

# Phones share WPA3 networks as T:SAE, while NetworkManager often saved the
# same network as wpa-psk, which also joins WPA3. That profile must be updated
# in place, not duplicated or switched to WPA3-only.
wpa_psk_only = profile("WIFI:S:Home;T:WPA;P:old-password;;", 100)
client.get_connections.return_value = [wpa_psk_only]
wpa3 = qr.parse_wifi("WIFI:S:Home;T:SAE;P:new-password;;")
check(qr.saved_profile(client, device, wpa3) is wpa_psk_only, "a WPA3 code updates a saved wpa-psk profile")
updated = qr.build_connection(wpa3, wpa_psk_only).get_setting_wireless_security()
check_equal((updated.get_key_mgmt(), updated.get_psk()), ("wpa-psk", "new-password"), "the updated profile keeps wpa-psk")
check(qr.saved_profile(client, device, qr.parse_wifi("WIFI:S:Home;T:SAE;P:short;;")) is None,
      "a WPA3 password too short for wpa-psk gets its own profile")
PY

run_python_test <<'PY'
# NetworkManager doubles: the async calls answer from the main loop the way
# libnm does, and the active connection then moves to `final_state`.
#
# Callbacks run the way PyGObject runs them: a user_data argument the caller
# passed, even None, arrives as a third callback argument. A callback that
# cannot take it never runs, and the join stalls into its timeout.
qr.CONNECT_TIMEOUT_SEC = 2

def call_back(args, index, source, then=None):
    callback, user_data = args[index], args[index + 1:]

    def run():
        callback(source, None, *user_data)
        if then:
            then()
        return GLib.SOURCE_REMOVE
    GLib.idle_add(run)

def fake_client(final_state, reason=NM.ActiveConnectionStateReason.UNKNOWN, connections=()):
    client = Mock()
    client.get_connections.return_value = list(connections)
    active = Mock()
    active.get_state.return_value = NM.ActiveConnectionState.ACTIVATING
    created = Mock()
    created.delete_async.side_effect = lambda *args: call_back(args, 1, created)
    client.get_connection_by_uuid.side_effect = lambda uuid: created

    def answer(*args):
        def settle():
            if final_state is not None:
                handler = active.connect.call_args.args[1]
                GLib.idle_add(lambda: handler(active, final_state, reason))
        call_back(args, 4, client, settle)

    client.add_and_activate_connection_async.side_effect = answer
    client.activate_connection_async.side_effect = answer
    client.add_and_activate_connection_finish.return_value = active
    client.activate_connection_finish.return_value = active
    return client, active, created

code = qr.parse_wifi("WIFI:S:Lab;T:WPA;P:password;;")
device = Mock()

client, active, created = fake_client(NM.ActiveConnectionState.ACTIVATED)
check_equal(raises(qr.connect, client, device, code), "", "a new network joins once NetworkManager reports it active")
settings = client.add_and_activate_connection_async.call_args.args[0]
check_equal(settings.get_setting_wireless_security().get_psk(), "password", "a new network is added with the code's password")
check(not created.delete_async.called, "a successful join keeps the new profile")

client, active, created = fake_client(NM.ActiveConnectionState.DEACTIVATED, NM.ActiveConnectionStateReason.NO_SECRETS)
check("rejected the password" in raises(qr.connect, client, device, code), "a rejected password says so")
check(created.delete_async.called, "a failed join removes the profile it created")

client, active, created = fake_client(None)
check("Timed out" in raises(qr.connect, client, device, code), "a join that never settles times out")
check(client.deactivate_connection_async.called and created.delete_async.called, "a timed-out join is stopped and its new profile removed")

# NetworkManager can save the profile and then go quiet before reporting the
# activation; the timeout must still find and remove it.
client, active, created = fake_client(None)
client.add_and_activate_connection_async.side_effect = None
check("Timed out" in raises(qr.connect, client, device, code), "a join with no activation reply times out")
uuid = client.add_and_activate_connection_async.call_args.args[0].get_uuid()
check_equal(client.get_connection_by_uuid.call_args.args[0], uuid, "the timeout looks up the profile it asked NetworkManager to add")
check(created.delete_async.called, "a profile saved before the timeout is removed")

# A saved profile is replaced on disk first, then activated, and stays
# updated when the join fails: the code holds the network's current password.
class Remote(NM.SimpleConnection):
    def update2(self, *args):
        self.update = args[:2]
        call_back(args, 4, self)

    def update2_finish(self, result):
        return True

saved = Remote()
for setting in qr.build_connection(qr.parse_wifi("WIFI:S:Lab;T:WPA;P:old-password;;")).get_settings():
    saved.add_setting(setting.duplicate())
client, active, created = fake_client(NM.ActiveConnectionState.DEACTIVATED, connections=[saved])
check("Could not connect" in raises(qr.connect, client, device, code), "a failed join of a saved network reports it")
check_equal(saved.update[1], NM.SettingsUpdate2Flags.TO_DISK, "a saved profile's new password is written to disk")
check(client.activate_connection_async.call_args.args[0] is saved, "the updated saved profile is the one activated")
check(not created.delete_async.called, "a failed join never deletes a saved profile")
PY

run_python_test <<'PY'
# The panel protocol: events never carry the password, nothing joins without
# an explicit "connect", and a missing radio fails before the camera opens.
code = qr.parse_wifi("WIFI:S:Lab;T:WPA;P:secret-password;;")

def run_main(stdin, **overrides):
    output = io.StringIO()
    patches = {"wifi_device": Mock(), "choose_camera": Mock(return_value="/dev/video0"),
               "scan": Mock(return_value=code), "saved_profile": Mock(return_value=None), "connect": Mock()}
    patches.update(overrides)
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(NM.Client, "new", return_value=Mock()))
        for name, value in patches.items():
            stack.enter_context(patch.object(qr, name, value))
        stack.enter_context(patch.object(sys, "argv", ["omarchy-network-qr-scan"]))
        stack.enter_context(patch.object(sys, "stdin", io.StringIO(stdin)))
        stack.enter_context(contextlib.redirect_stdout(output))
        qr.main()
    return [json.loads(line) for line in output.getvalue().splitlines()], patches

events, mocks = run_main("")
check_equal([event["event"] for event in events], ["ready"], "the helper waits for confirmation after a scan")
check_equal(events[0], {"event": "ready", "ssid": "Lab", "security": "WPA", "hidden": False, "saved": False},
            "the ready event names the network without its password")
check(not mocks["connect"].called, "closing stdin never joins")

events, mocks = run_main("connect\n", saved_profile=Mock(return_value=object()))
check_equal([event["event"] for event in events], ["ready", "connecting", "connected"], "confirmation joins and reports the outcome")
check(events[0]["saved"], "the ready event says when a saved password will be replaced")
check(all("secret-password" not in json.dumps(event) for event in events), "no event carries the password")

events, mocks = run_main("", scan=Mock(return_value=None))
check_equal([event["event"] for event in events], ["cancelled"], "a closed preview reports a cancellation")

events, mocks = run_main("connect\n", wifi_device=Mock(side_effect=qr.WifiError("Wi-Fi is turned off. Turn it on and try again.")))
check_equal(events, [{"event": "error", "message": "Wi-Fi is turned off. Turn it on and try again."}], "a missing radio is reported as an error")
check(not mocks["choose_camera"].called, "the camera stays off when there is nothing to join with")

events, mocks = run_main("connect\n", connect=Mock(side_effect=qr.WifiError("Timed out connecting.")))
check_equal(events[-1], {"event": "error", "message": "Timed out connecting."}, "a failed join ends with its error")
PY

run_node_test <<'JS'
const network = requireFromRoot('shell/plugins/panels/network/Model.js')

const idle = { state: 'idle', network: null, error: '' }
const scanning = { state: 'scanning', network: null, error: '' }
const ready = network.qrScanStep(scanning, { event: 'ready', ssid: 'Lab', security: 'WPA', hidden: false, saved: true })
assertDeepEqual(ready, { state: 'ready', network: { ssid: 'Lab', security: 'WPA', hidden: false, saved: true }, error: '' }, 'a scanned code waits for confirmation')

const connecting = network.qrScanStep(ready, { event: 'connecting' })
assertEqual(connecting.network.ssid, 'Lab', 'connecting keeps the scanned network')
assertDeepEqual(network.qrScanStep(connecting, { event: 'connected' }), idle, 'a finished join hands over to the panel\'s own connected state')
assertDeepEqual(network.qrScanStep(scanning, { event: 'cancelled' }), idle, 'closing the preview returns to idle')
assertEqual(network.qrScanStep(scanning, { event: 'error', message: 'No webcam found.' }).error, 'No webcam found.', 'helper errors reach the panel')

const lostJoin = network.qrScanStep(connecting, { event: 'exit' })
assert(lostJoin.state === 'error' && /before the connection finished/.test(lostJoin.error),
  'a helper lost mid-join does not blame the webcam')

for (const state of ['scanning', 'ready', 'connecting']) {
  const crashed = network.qrScanStep({ state, network: null, error: '' }, { event: 'exit' })
  assertEqual(crashed.state, 'error', `a helper exit while ${state} is reported`)
}
const failed = { state: 'error', network: null, error: 'No webcam found.' }
assert(network.qrScanStep(failed, { event: 'exit' }) === failed, 'the exit after a reported error keeps that error')
assert(network.qrScanStep(idle, { event: 'exit' }) === idle, 'the exit after a cancel stays idle')

assertEqual(network.qrScanDetail({ ssid: 'Lab', security: 'WPA', hidden: false, saved: true }, 'Home'),
  'WPA · Replaces the saved password · Disconnects Home', 'the prompt says what joining changes')
assertEqual(network.qrScanDetail({ ssid: 'Cafe', security: 'NOPASS', hidden: true, saved: false }, 'Cafe'),
  'Open network · Hidden · New network', 'the prompt describes an open hidden network')
JS

require_compositor "network QR scan runtime test"
require_command quickshell

# The real panel against a scripted helper: each scan run plays the next
# scene, so the QML state machine, focus, and process handling run for real
# with no camera or NetworkManager involved.
stage="$tmp/stage"
fixture="$SHELL_TEST_DIR/fixtures/network-qr-scan"
mkdir -p "$stage/network" "$stage/bin" "$stage/home" "$stage/runs"
ln -s "$ROOT/shell/Ui" "$stage/Ui"
ln -s "$ROOT/shell/Commons" "$stage/Commons"
cp -r "$SHELL_TEST_DIR/fixtures/network-panel/mocks" "$stage/mocks"
cp "$fixture/shell.qml" "$stage/shell.qml"
cp "$ROOT/shell/plugins/panels/network/Model.js" "$stage/network/Model.js"
node - "$ROOT" "$stage" <<'JS'
const fs = require('fs')
const [root, stage] = process.argv.slice(2)
let source = fs.readFileSync(`${root}/shell/plugins/panels/network/Panel.qml`, 'utf8')
source = source.replace('import Quickshell.Networking', 'import Quickshell.Networking\nimport "../mocks"')
source = source.replace(/\bNetworking\./g, 'NetworkMock.')
source = source.replace('  id: root', `  id: root
  property alias testKeys: keyCatcher
  property alias testScan: scanAction
  property alias testScanProc: qrScanProc
  property alias testConnect: qrScanConnect
  property alias testRetry: qrScanRetry
  property alias testCancel: qrScanCancel
  property alias testQrBlock: qrScanBlock`)
fs.writeFileSync(`${stage}/network/Panel.qml`, source)
JS

printf '#!/bin/bash\nexit 0\n' >"$stage/bin/noop"
chmod +x "$stage/bin/noop"
for command in omarchy-dns omarchy-network-band omarchy-notification-send; do
  ln -s noop "$stage/bin/$command"
done
# Synthetic details only, never the host's SSID or addresses.
printf '#!/bin/bash\nprintf "type\\twifi\\niface\\ttest-wifi\\nssid\\tGuest Wi-Fi\\nip\\t192.0.2.10\\ngateway\\t192.0.2.1\\n"\n' >"$stage/bin/omarchy-network-status"
chmod +x "$stage/bin/omarchy-network-status"

cat >"$stage/bin/omarchy-network-qr-scan" <<'EOF'
#!/bin/bash
run=$(( $(ls "$QR_TEST_DIR/runs" | wc -l) + 1 ))
printf '%s\n' "$*" >"$QR_TEST_DIR/runs/$run"
printf '%s\n' "$$" >"$QR_TEST_DIR/pid-$run"
ready='{"event":"ready","ssid":"Lab","security":"WPA","hidden":false,"saved":true}'
case $run in
  1)
    echo '{"event":"ready","ssid":"Guest Wi-Fi","security":"WPA","hidden":false,"saved":true}'
    read -r reply
    printf '%s\n' "$reply" >"$QR_TEST_DIR/reply-1"
    echo '{"event":"connecting","ssid":"Guest Wi-Fi","security":"WPA","hidden":false}'
    echo '{"event":"connected","ssid":"Guest Wi-Fi","security":"WPA","hidden":false}'
    ;;
  2) echo '{"event":"error","message":"No webcam found. Check the camera connection or privacy switch, then try again."}' ;;
  3)
    echo "$ready"
    read -r reply
    printf '%s\n' "$reply" >"$QR_TEST_DIR/reply-3"
    ;;
  4) exit 3 ;;
  5) echo '{"event":"cancelled"}' ;;
  6)
    echo '{"event":"ready","ssid":"Guest Wi-Fi","security":"WPA","hidden":false,"saved":true}'
    read -r reply
    echo '{"event":"connecting","ssid":"Guest Wi-Fi","security":"WPA","hidden":false}'
    sleep 0.3
    echo '{"event":"error","message":"The network rejected the password. Check that the QR code is current."}'
    ;;
  7)
    echo "$ready"
    read -r reply
    printf '%s\n' "$reply" >"$QR_TEST_DIR/reply-7"
    ;;
esac
EOF
chmod +x "$stage/bin/omarchy-network-qr-scan"

run_fixture() {
  HOME="$stage/home" OMARCHY_PATH="$ROOT" PATH="$stage/bin:$PATH" QR_TEST_DIR="$stage" \
    timeout 40 quickshell -p "$stage" --no-color 2>&1
}

output=$(run_fixture) || fail "network QR scan fixture exits cleanly" "$output"
[[ $output == *"RESULT pass"* ]] || fail "network QR scan runtime assertions pass" "$output"
if rg -q 'RESULT fail|ReferenceError|TypeError|Error:|Unable to assign|Binding loop' <<<"$output"; then
  fail "network QR scan fixture has no QML errors" "$output"
fi
pass "the panel drives every scan outcome through to the right state"

for run in 1 2 3 4 5 6 7; do
  [[ $(<"$stage/runs/$run") == "--interface test-wifi" ]] || fail "every scan names the panel's Wi-Fi interface" "run $run: $(<"$stage/runs/$run")"
done
pass "every scan names the panel's Wi-Fi interface"

[[ $(<"$stage/reply-1") == "connect" ]] || fail "Connect sends the helper its go-ahead"
pass "Connect sends the helper its go-ahead"

[[ ! -e $stage/reply-3 ]] || fail "Cancel never tells the helper to connect" "$(<"$stage/reply-3")"
! kill -0 "$(<"$stage/pid-3")" 2>/dev/null || fail "Cancel stops the waiting helper"
pass "Cancel stops the waiting helper without connecting"

[[ ! -e $stage/reply-7 ]] || fail "closing the panel never tells the helper to connect" "$(<"$stage/reply-7")"
! kill -0 "$(<"$stage/pid-7")" 2>/dev/null || fail "closing the panel stops the waiting helper"
pass "closing the panel stops the waiting helper without connecting"

if [[ -n ${QR_TEST_SCREENSHOT_DIR:-} ]]; then
  for state in default ready error; do
    QR_TEST_PREVIEW=$state QR_TEST_SCREENSHOT="$QR_TEST_SCREENSHOT_DIR/network-qr-$state.png" run_fixture >/dev/null
  done
fi
