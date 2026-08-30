import AppKit
import SwiftUI

/// Click to arm, then press any key combination. While armed a local key-down monitor
/// swallows the event so the shortcut is recorded instead of being executed by the window.
struct ShortcutRecorderView: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .monospaced()
                .frame(minWidth: 90)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private var label: String {
        if isRecording { return Strings.buttonRecording }
        if let combo { return KeyCodeNames.describe(combo) }
        return Strings.buttonRecordShortcut
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return nil }
            if event.keyCode == UInt16(53) { // Escape cancels
                stop()
                return nil
            }
            let modifiers = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .rawValue & EventRouter.modifierMask
            combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
