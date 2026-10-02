import QtQuick
import Quickshell
import Quickshell.Networking
import qs.Commons
import "mocks"
import "network" as Network

ShellRoot {
  id: test
  property bool failed: false
  function check(ok, message) {
    if (!ok) {
      failed = true
      console.log("RESULT fail " + message)
    }
  }

  Item {
    Network.Panel {
      id: panel
      bar: QtObject {
        property color foreground: Color.foreground
        property color barForeground: Color.foreground
        property color urgent: Color.urgent
        property string fontFamily: Style.font.family
        property string position: "top"
        property int barSize: 24
        property bool vertical: false
        property bool foregroundAnimationEnabled: false
        property var activePopout: null
        function requestPopout(owner) { activePopout = owner }
        function releasePopout(owner) { activePopout = null }
        function registerClickTarget(target) {}
        function unregisterClickTarget(target) {}
        function hideTooltip(target) {}
        function showTooltip(target, text) {}
      }
    }
  }

  // The stub helper answers from the main loop, so each step waits for the
  // panel to reach the state the helper's events should put it in.
  property var waiting: null
  function waitFor(condition, label, next) {
    waiting = { condition: condition, label: label, next: next, deadline: Date.now() + 5000 }
    poll.start()
  }
  Timer {
    id: poll
    interval: 50
    repeat: true
    onTriggered: {
      if (test.waiting.condition()) {
        stop()
        test.waiting.next()
      } else if (Date.now() > test.waiting.deadline) {
        stop()
        test.check(false, "timed out waiting for " + test.waiting.label)
        Qt.quit()
      }
    }
  }

  Timer {
    interval: 250
    running: true
    onTriggered: {
      var preview = Quickshell.env("QR_TEST_PREVIEW")
      if (preview) { test.showPreview(preview); return }

      // The share action appears once the stubbed details report Wi-Fi.
      test.waitFor(function() { return panel.canShareWifi }, "the connection details", test.headerChecks)
    }
  }

  function headerChecks() {
    check(panel.testScan.visible && panel.scanHeaderIndex === 1, "camera action sits after QR sharing in the header")
    NetworkMock.wifiEnabled = false
    check(!panel.testScan.visible && panel.scanHeaderIndex === -1, "camera action hides while Wi-Fi is off")
    NetworkMock.wifiEnabled = true

    panel.open()
    panel.testKeys.textKey("q", 0)
    check(panel.qrScanState === "scanning" && panel.testScanProc.running, "Q starts the helper")
    check(!panel.opened, "the panel steps aside for the camera preview")
    waitFor(function() { return panel.qrScanState === "ready" }, "the first scan", confirmScan)
  }

  function confirmScan() {
    check(panel.opened, "a scanned code reopens the panel")
    check(panel.testKeys.blocked, "the confirmation owns the keyboard")
    check(panel.testConnect.visible && panel.testConnect.activeFocus, "Connect takes focus")
    check(!panel.testRetry.visible, "Try again stays hidden on a fresh code")
    panel.testConnect.clicked()
    check(panel.qrScanState === "connecting" && panel.busy, "confirming locks the other Wi-Fi actions")
    check(!panel.testKeys.blocked, "the keyboard returns to the panel while connecting")
    check(panel.actionKind === "connect" && panel.actionSsid === "Guest Wi-Fi" && !panel.testQrBlock.visible,
      "a listed network shows the join on its own row, not inline")
    waitFor(function() { return panel.qrScanState === "idle" && !panel.testScanProc.running }, "the join", connectedChecks)
  }

  function connectedChecks() {
    check(!panel.busy && panel.actionKind === "", "a finished join releases the row and unlocks the panel")
    check(!panel.testQrBlock.visible, "a finished join leaves no QR text behind")
    panel.qrScan = { state: "connecting", network: { ssid: "Lab", security: "WPA", hidden: true, saved: false }, error: "" }
    check(panel.testQrBlock.visible, "a network with no row shows the join inline")
    panel.qrScan = { state: "idle", network: null, error: "" }
    panel.close()
    panel.startQrScan()
    waitFor(function() { return panel.qrScanState === "error" && !panel.testScanProc.running }, "the scan error", errorChecks)
  }

  function errorChecks() {
    check(panel.opened && panel.qrScan.error.indexOf("No webcam found") === 0, "a helper error shows in the panel")
    check(panel.testRetry.visible && panel.testRetry.activeFocus, "Try again takes focus after an error")
    panel.testRetry.clicked()
    waitFor(function() { return panel.qrScanState === "ready" }, "the retried scan", cancelChecks)
  }

  function cancelChecks() {
    panel.testCancel.clicked()
    check(panel.qrScanState === "idle" && !panel.testKeys.blocked, "Cancel drops the prompt and frees the keyboard")
    waitFor(function() { return !panel.testScanProc.running }, "the cancelled helper to stop", function() {
      panel.startQrScan()
      test.waitFor(function() { return panel.qrScanState === "error" }, "the crashed helper", crashChecks)
    })
  }

  function crashChecks() {
    check(panel.qrScan.error.indexOf("stopped") >= 0, "a helper that dies without a word is reported")
    panel.close()
    panel.startQrScan()
    waitFor(function() { return panel.qrScanState === "idle" && !panel.testScanProc.running }, "the closed preview", function() {
      test.check(panel.opened, "closing the preview brings the panel back")
      // A secured network, so a failure reopens the row's password prompt.
      NetworkMock.network.security = WifiSecurityType.Wpa2Psk
      panel.startQrScan()
      test.waitFor(function() { return panel.qrScanState === "ready" }, "the wrong-password scan", wrongPasswordChecks)
    })
  }

  // NetworkManager's own failure reaches the row before the helper explains
  // it; the explanation is all that should be left.
  function wrongPasswordChecks() {
    panel.testConnect.clicked()
    NetworkMock.network.connectionFailed(ConnectionFailReason.NoSecrets)
    check(panel.passwordSsid === "Guest Wi-Fi", "the row's own failure handling ran")
    waitFor(function() { return panel.qrScanState === "error" }, "the rejected password", function() {
      test.check(panel.qrScan.error.indexOf("rejected the password") >= 0, "the helper's explanation shows inline")
      test.check(panel.failureReason === "" && panel.passwordSsid === "", "the row drops its own failure and password prompt")
      NetworkMock.network.security = WifiSecurityType.Open
      panel.testCancel.clicked()
      panel.startQrScan()
      test.waitFor(function() { return panel.qrScanState === "ready" }, "the abandoned scan", closeChecks)
    })
  }

  function closeChecks() {
    panel.close()
    check(panel.qrScanState === "idle", "closing the panel drops an unanswered prompt")
    waitFor(function() { return !panel.testScanProc.running }, "the abandoned helper to stop", function() {
      if (!test.failed) console.log("RESULT pass")
      Qt.quit()
    })
  }

  // QR_TEST_PREVIEW=default|ready|error with QR_TEST_SCREENSHOT=<path> renders
  // one synthetic state of the real card for visual review.
  function showPreview(state) {
    if (state === "ready") {
      panel.qrScan = { state: "ready", network: { ssid: "Lab", security: "WPA", hidden: false, saved: true }, error: "" }
    } else if (state === "error") {
      panel.qrScan = { state: "error", network: null, error: "No QR code detected. Enlarge the code on your phone, hold it steady, and try again." }
    }
    panel.open()
    previewCapture.start()
  }

  Timer {
    id: previewCapture
    interval: 750
    onTriggered: {
      var card = panel.testKeys.parent.parent
      card.grabToImage(function(result) {
        test.check(result.saveToFile(Quickshell.env("QR_TEST_SCREENSHOT")), "save preview screenshot")
        Qt.quit()
      })
    }
  }
}
