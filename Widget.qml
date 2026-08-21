// Cast control in the Omarchy bar.
//
// Built from the shell's own components so it reads like the network and audio
// panels: a hero row, filled row cards, pill choices, and section headers.
//
// The first draft of this panel put a mirror icon and an extend icon on every
// row. With eighteen laptops on an office network that is thirty-six identical
// grey glyphs and a list running off the bottom of the screen. The mode is now
// picked ONCE, as a pill, and a receiver row is a single click -- the same
// shape as choosing a DNS provider and then a network next door.
//
// Everything it knows comes from three castr commands:
//
//   castr bar            polled every 2s; NEVER spawns a daemon, so polling
//                        cannot keep one alive past its idle timeout
//   castr list --json    receivers, read only while the panel is open
//   castr status --json  live casts, read only while the panel is open
//
// It parses JSON rather than scraping the human output, which would break the
// moment a column width changed.
//
//
// Receiver names, models and addresses come from mDNS -- from anything on the
// network that cares to advertise. QML's default textFormat is AutoText, which
// sniffs for rich text, so a receiver advertising itself as
// `<img src="http://attacker/x">` would have this widget FETCH that URL. It is
// not hypothetical: a name of `<b>PWNED</b>` rendered in bold before this was
// set. Reported by @ryanrhughes against commit eb22e2c.
//
// The rule is all of them rather than only the ones carrying remote data, so a
// Text added later is safe by default instead of by review.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "castr.indicator"
  ipcTarget: "castr.indicator"

  // ---- from `castr bar`, polled whether or not the panel is open ----
  property string castState: "idle"      // idle | connecting | streaming | failed
  property string tooltip: "Not casting"
  readonly property bool casting: castState === "streaming"
  readonly property bool busy: castState === "connecting"
  readonly property bool failed: castState === "failed"

  // ---- read only while the panel is open ----
  property var devices: []
  property var sessions: []
  property bool loading: false
  property string listError: ""
  property string mode: "mirror"         // the pill, applied to whatever is clicked
  property string actionDeviceId: ""

  // Whether the castr binary exists at all. Checked through sh, because a
  // Process whose binary is missing emits NO onExited -- it fails to start and
  // says nothing, so the obvious "did it exit non-zero" test never fires. sh is
  // always present, so its exit code is a signal we actually receive.
  property bool installed: true
  property bool installChecked: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color rowFill: Style.normalFillFor(fg)
  readonly property color rowHover: Style.hoverFillFor(fg, Color.accent)
  readonly property color rowLive: Style.selectedFillFor(fg, Color.accent)

  readonly property int rowHeight: Style.space(40)
  readonly property int rowGap: Style.spacing.sm
  // Four rows and a peek at the fifth. The peek is the scroll affordance --
  // deliberate, unlike the arbitrary slice the panel edge made of the last row
  // when the cap was a round number of pixels.
  readonly property int visibleRows: 4

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // plain() strips the characters a rich-text sniffer needs to see a tag.
  //
  // through a Text this file owns -- the shell's PanelToolTip renders into its
  // own bare Text, which defaults to AutoText. Receiver names reach those
  // tooltips, so they are neutered before they leave this file. Removing the
  // angle brackets is deterministic; relying on the sniffer's judgement is not.
  function plain(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/[<>]/g, "")
  }

  function refreshStatus() { if (!statusProc.running) statusProc.running = true }

  function refreshPanel() {
    if (!root.opened || !root.installed) return
    root.loading = true
    if (!listProc.running) listProc.running = true
    if (!sessionsProc.running) sessionsProc.running = true
  }

  // Keyed on device id, never on name: two Apple TVs can share a name and only
  // the id is unique.
  function sessionFor(deviceId) {
    for (var i = 0; i < root.sessions.length; i++)
      if (root.sessions[i].device_id === deviceId) return root.sessions[i]
    return null
  }

  // A television is what you cast to; a colleague's laptop answering AirPlay is
  // noise. Sorting them up is the difference between a list you scan and a list
  // you search.
  function isTelevision(device) {
    var model = String(device.model || "")
    return model.indexOf("AppleTV") === 0 || model.indexOf("TV") >= 0
  }

  function orderedDevices() {
    var live = [], tvs = [], rest = []
    for (var i = 0; i < root.devices.length; i++) {
      var d = root.devices[i]
      if (root.sessionFor(d.id)) live.push(d)
      else if (isTelevision(d)) tvs.push(d)
      else rest.push(d)
    }
    function byName(a, b) {
      return String(a.name || "").toLowerCase() < String(b.name || "").toLowerCase() ? -1 : 1
    }
    return tvs.sort(byName).concat(rest.sort(byName))
  }

  function subtitleFor(device) {
    if (root.actionDeviceId === device.id)
      return root.mode === "extend" ? "Extending…" : "Mirroring…"
    if (device.model) return device.model
    // A receiver added by hand has no name of its own, so castr uses the
    // address for both. Printing it twice tells the reader nothing; saying
    // where it came from does.
    if (device.name === device.address) return "Added by hand"
    return device.address
  }

  function startCast(deviceId) {
    root.actionDeviceId = deviceId
    startProc.command = ["castr", "start", deviceId, root.mode]
    startProc.running = true
    // Closed straight away: a cast takes most of a minute to come up, and the
    // answer belongs on the bar and in a notification, not in a panel held open
    // waiting for something to happen.
    root.close()
  }

  function stopCast(deviceId) {
    root.actionDeviceId = deviceId
    stopProc.command = deviceId ? ["castr", "stop", deviceId] : ["castr", "stop"]
    stopProc.running = true
  }

  onOpenedChanged: {
    if (opened) refreshPanel()
    else { root.listError = ""; root.actionDeviceId = "" }
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: installProc
    command: ["sh", "-c", "command -v castr >/dev/null"]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      root.installChecked = true
    }
  }

  Process {
    id: statusProc
    command: ["castr", "bar"]
    stdout: StdioCollector {
      onStreamFinished: {
        // A half-written or missing line must not wedge the indicator: fall
        // back to idle rather than showing a stale "streaming" forever.
        try {
          var data = JSON.parse(String(text || "").trim() || "{}")
          root.castState = String(data["class"] || "idle")
          root.tooltip = String(data.tooltip || "Not casting")
        } catch (e) {
          root.castState = "idle"
          root.tooltip = "Not casting"
        }
      }
    }
  }

  Process {
    id: listProc
    command: ["castr", "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.loading = false
        try {
          var data = JSON.parse(String(text || "").trim() || "{}")
          root.devices = data.devices || []
          root.listError = String(data.error || "")
        } catch (e) {
          root.devices = []
          root.listError = "could not read the receiver list"
        }
      }
    }
  }

  Process {
    id: sessionsProc
    command: ["castr", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "").trim() || "{}")
          root.sessions = data.sessions || []
        } catch (e) {
          root.sessions = []
        }
      }
    }
  }

  Process {
    id: startProc
    onExited: { root.actionDeviceId = ""; root.refreshStatus() }
  }

  Process {
    id: stopProc
    onExited: { root.actionDeviceId = ""; root.refreshStatus(); root.refreshPanel() }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Re-checked, not checked once: someone installing castr while the shell
      // runs should see the widget come alive without restarting anything.
      if (!installProc.running) installProc.running = true
      if (root.installed) root.refreshStatus()
    }
  }

  Timer {
    // While the panel is open, keep the list fresh: mDNS turns receivers up a
    // few seconds apart, and a list that never grows looks broken.
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refreshPanel()
  }

  // ------------------------------------------------------------------ the bar

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // Visible in every state rather than hidden when idle: a control you
    // cannot see is a control you cannot find, and this one stops the cast.
    text: root.casting ? "󰄠" : "󰄡"
    active: root.casting || root.busy
    tooltipText: root.installed
      ? root.plain(root.tooltip)
      : "castr is not installed\nInstall it with:  yay -S castr doubletake-git"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.installed && (root.casting || root.busy)) root.stopCast("")
      } else {
        root.toggle()
      }
    }
  }

  // ---------------------------------------------------------------- the panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.lg

        // ---------- hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: root.casting ? "󰄠" : "󰄡"
            textFormat: Text.PlainText
            // The theme's own palette: a theme sets foreground/accent/urgent,
            // and inventing colours would ignore whatever the user chose.
            color: root.failed ? Color.urgent : root.casting ? Color.accent : root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              text: "Cast"
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              // "Not casting" and "castr is not installed" look identical
              // otherwise, and the second is the one the reader can act on.
              text: !root.installed ? "castr is not installed"
                  : String(root.tooltip).split("\n")[0]
              textFormat: Text.PlainText
              color: (root.failed || !root.installed) ? Color.urgent
                   : Qt.darker(root.fg, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Look for receivers again"
            foreground: root.fg
            fontFamily: root.bar.fontFamily
            onClicked: root.refreshPanel()
          }
        }

        // ---------- what is casting now ----------
        Repeater {
          model: root.sessions
          delegate: BorderSurface {
            required property var modelData
            width: column.width
            height: Style.space(38)
            color: root.rowLive
            radius: Style.cornerRadius
            borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: liveStop.left
              anchors.rightMargin: Style.spacing.md
              text: modelData.name
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            PanelActionButton {
              id: liveStop
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰓛"
              tooltipText: "Stop casting to " + root.plain(modelData.name)
              foreground: root.fg
              hoverColor: Color.urgent
              fontFamily: root.bar.fontFamily
              onClicked: root.stopCast(modelData.device_id)
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.fg
          visible: root.sessions.length > 0
        }

        // ---------- nothing to drive: say so, with the way out ----------
        Text {
          width: parent.width
          visible: !root.installed
          text: "This widget drives the castr command, which is not on your PATH.\n\n"
              + "    yay -S castr doubletake-git\n\n"
              + "The bar picks it up on its own once it is installed."
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.2)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- mode, chosen once ----------
        PanelSectionHeader {
          visible: root.installed
          width: parent.width
          text: "MODE"
          textFormat: Text.PlainText
          foreground: root.fg
          fontFamily: root.bar.fontFamily
        }

        ButtonGroup {
          width: parent.width
          visible: root.installed
          options: [
            { value: "mirror", label: "Mirror" },
            { value: "extend", label: "Extend" }
          ]
          value: root.mode
          foreground: root.fg
          accent: Color.accent
          fontFamily: root.bar.fontFamily
          onChanged: function(value) { root.mode = value }
        }

        Text {
          width: parent.width
          visible: root.installed
          text: root.mode === "extend"
            ? "A second desktop on the receiver. Pick the castr output if asked what to share."
            : "Shows this screen on the receiver."
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          width: parent.width
          foreground: root.fg
          visible: root.installed
        }

        // ---------- receivers ----------
        PanelSectionHeader {
          width: parent.width
          visible: root.installed
          text: root.loading && root.devices.length === 0 ? "LOOKING FOR RECEIVERS" : "RECEIVERS"
          textFormat: Text.PlainText
          foreground: root.fg
          fontFamily: root.bar.fontFamily
        }

        Text {
          width: parent.width
          visible: root.listError !== ""
          text: root.listError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.installed && root.listError === "" && !root.loading && root.devices.length === 0
          text: "Nothing is advertising AirPlay here. A receiver that does not "
              + "answer mDNS can still be added: castr add <address>"
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Capped and scrollable. An office network answers with every laptop in
        // the building; without a ceiling the panel runs off the bottom of the
        // screen and the receiver you actually want is somewhere past the edge.
        Flickable {
          width: parent.width
          height: Math.min(receiverColumn.implicitHeight,
                           root.visibleRows * (root.rowHeight + root.rowGap)
                             + root.rowHeight / 2)
          contentHeight: receiverColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          visible: root.installed && root.devices.length > 0

          Column {
            id: receiverColumn
            width: parent.width
            spacing: root.rowGap

            Repeater {
              model: root.orderedDevices()
              delegate: BorderSurface {
                id: row
                required property var modelData
                readonly property bool pending: root.actionDeviceId === modelData.id
                width: receiverColumn.width
                height: root.rowHeight
                color: pending ? root.rowHover
                     : rowMouse.containsMouse ? root.rowHover
                     : root.rowFill
                radius: Style.cornerRadius
                borderSpec: Border.controlSpec(rowMouse.containsMouse ? "hover" : "normal",
                                               root.fg, Color.accent)

                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                  id: rowIcon
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.lg
                  anchors.verticalCenter: parent.verticalCenter
                  // A television and a laptop are different things to cast to,
                  // and the glyph says which without reading the model string.
                  text: root.isTelevision(modelData) ? "󰔂" : "󰌢"
                  textFormat: Text.PlainText
                  color: rowMouse.containsMouse ? Color.accent : Qt.darker(root.fg, 1.2)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Column {
                  anchors.left: rowIcon.right
                  anchors.leftMargin: Style.spacing.lg
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.lg
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    text: modelData.name
                    textFormat: Text.PlainText
                    color: root.fg
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    text: root.subtitleFor(modelData)
                    textFormat: Text.PlainText
                    color: Qt.darker(root.fg, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !row.pending
                  onClicked: root.startCast(modelData.id)
                }
              }
            }
          }
        }
      }
    }
  }
}
