import QtQuick
import QtQuick.Layouts
import "ui"

// Pick the recording overlay's look, with live previews of both styles.
Flickable {
  id: root
  required property var theme
  required property var store
  property bool active: true
  contentHeight: col.implicitHeight + 48
  clip: true
  boundsBehavior: Flickable.StopAtBounds

  readonly property var styles: [
    { value: "neon", name: "Neon", blurb: "A glowing waveform pill. Swells with loudness, moves faster when you talk faster, throws thin sparks on stressed syllables." },
    { value: "trace", name: "Trace", blurb: "A lie detector pen on scrolling paper. Calm baseline in silence, jagged peaks as your voice rises, with grainy ASCII glow in a cyberpunk panel." },
    { value: "scope", name: "Scope", blurb: "A synth oscilloscope in the same ASCII panel. Stays in place and reacts instantly: a soft wave when you are quiet, taller with sharper harmonics as you get louder, with a phosphor ghost of the moment before." },
    { value: "clip", name: "Clip", blurb: "A DAW clip waveform that grows out from the center, so your newest sound is always in the middle and nothing waits for paper to scroll. Goes flat the moment you stop." }
  ]

  ColumnLayout {
    id: col
    x: 32
    y: 28
    width: root.width - 64
    spacing: 18

    Label { theme: root.theme; heading: true; text: "Overlay style" }
    Label {
      theme: root.theme; dim: true; Layout.fillWidth: true
      text: "What shows on screen while you dictate. Every style follows your Omarchy theme and switches the next time the overlay opens, or right away if it is showing."
    }

    GridLayout {
      Layout.fillWidth: true
      columns: root.width > 1000 ? 2 : 1
      columnSpacing: 18
      rowSpacing: 18

      Repeater {
        model: root.styles
        Rectangle {
          id: card
          required property var modelData
          readonly property bool chosen: root.store.settings.overlay_style === modelData.value
          Layout.fillWidth: true
          Layout.preferredHeight: inner.implicitHeight + 32
          color: chosen ? root.theme.selected : (hover.containsMouse ? root.theme.surfaceHover : root.theme.surface)
          border.width: 1
          border.color: chosen ? Qt.alpha(root.theme.accent, 0.9) : root.theme.border
          Behavior on color { ColorAnimation { duration: 120 } }

          ColumnLayout {
            id: inner
            x: 16
            y: 16
            width: parent.width - 32
            spacing: 12

            RowLayout {
              Layout.fillWidth: true
              Label { theme: root.theme; text: card.modelData.name; font.pixelSize: root.theme.size + 2; font.weight: Font.DemiBold }
              Item { Layout.fillWidth: true }
              Rectangle {
                visible: card.chosen
                implicitWidth: tag.implicitWidth + 14
                implicitHeight: 22
                color: "transparent"
                border.width: 1
                border.color: root.theme.accent
                Label { id: tag; theme: root.theme; small: true; anchors.centerIn: parent; text: "IN USE"; color: root.theme.accent; font.letterSpacing: 1 }
              }
            }

            // Backdrop in the theme's colors so the pill reads as it will over a window.
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: preview.implicitHeight + 28
              gradient: Gradient {
                GradientStop { position: 0; color: Qt.darker(root.theme.bg, root.theme.dark ? 1.5 : 1.04) }
                GradientStop { position: 1; color: Qt.lighter(root.theme.bg, root.theme.dark ? 1.3 : 0.97) }
              }
              border.width: 1
              border.color: root.theme.border
              clip: true
              StylePreview {
                id: preview
                anchors.centerIn: parent
                theme: root.theme
                style: card.modelData.value
                zoom: Math.min(1.6, (parent.width - 20) / 288)
                running: root.active
              }
            }

            Label { theme: root.theme; dim: true; Layout.fillWidth: true; text: card.modelData.blurb }
          }
          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: card.chosen ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: if (!card.chosen) root.store.set("overlay_style", card.modelData.value)
          }
        }
      }
    }

    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.theme.border; Layout.topMargin: 6 }

    GridLayout {
      columns: 2
      columnSpacing: 24
      rowSpacing: 14
      Label { theme: root.theme; text: "Show the overlay" }
      Segmented {
        theme: root.theme
        options: [{ label: "On", value: true }, { label: "Off", value: false }]
        value: root.store.settings.overlay !== false
        onPicked: function(v) { root.store.set("overlay", v) }
      }
      Label { theme: root.theme; text: "Position" }
      Segmented {
        theme: root.theme
        options: [{ label: "Top", value: "top" }, { label: "Bottom", value: "bottom" }]
        value: root.store.settings.overlay_position || "top"
        onPicked: function(v) { root.store.set("overlay_position", v) }
      }
    }
  }
}
