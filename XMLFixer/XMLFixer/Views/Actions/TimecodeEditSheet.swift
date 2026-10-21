import SwiftUI

struct TimecodeEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var timecodeText: String = "01:00:00:00"
    @State private var displayFormat: String = "NDF"

    // The target sequence (if single mode) — set from appState.timecodeEditTargetSequenceID
    private var targetSequence: SequenceInfo? {
        guard let targetID = appState.timecodeEditTargetSequenceID else { return nil }
        return appState.documents.flatMap(\.sequences).first { $0.id == targetID }
    }

    private var targetSequences: [SequenceInfo] {
        if let targetSequence { return [targetSequence] }
        return appState.documents.flatMap(\.sequences)
    }

    private var isValid: Bool {
        !targetSequences.isEmpty && targetSequences.allSatisfy {
            Timecode.parse(timecodeText, timebase: $0.timebase ?? 25, dropFrame: displayFormat == "DF") != nil
        }
    }

    private var referenceTC: Timecode? {
        guard let targetID = appState.timecodeEditTargetSequenceID,
              let match = appState.referenceMatches[targetID] else { return nil }
        return match.selectedTimecode
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Start Timecode")
                .font(.headline)

            Form {
                if let seq = targetSequence {
                    LabeledContent("Sequence") {
                        Text(seq.name)
                    }
                    LabeledContent("Current TC") {
                        Text(seq.startTimecodeString ?? "00:00:00:00")
                            .font(.system(.body, design: .monospaced))
                    }
                }

                LabeledContent("New Timecode") {
                    TimecodeTextField(text: $timecodeText,
                        timebase: targetSequence?.timebase ?? targetSequences.first?.timebase ?? 25,
                        dropFrame: displayFormat == "DF")
                        .frame(width: 150, height: 24)
                }

                Picker("Display Format", selection: $displayFormat) {
                    Text("Non-Drop Frame").tag("NDF")
                    Text("Drop Frame").tag("DF")
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                if targetSequence == nil {
                    // Batch mode - show all sequences that will be affected
                    let allSequences = appState.documents.flatMap(\.sequences)
                    LabeledContent("Applies to") {
                        Text("\(allSequences.count) sequences across \(appState.documents.count) XMLs")
                            .foregroundStyle(.secondary)
                    }
                }

                if let refTC = referenceTC {
                    Divider()
                    HStack {
                        Text("Reference TC:")
                            .foregroundStyle(.secondary)
                        Text(refTC.description)
                            .font(.system(.body, design: .monospaced))
                        Button("Use Reference TC") {
                            timecodeText = refTC.description
                            displayFormat = refTC.isDropFrame ? "DF" : "NDF"
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)

            if !isValid {
                Text("Enter a valid timecode for the sequence frame rate (digits or HH:MM:SS:FF).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    applyTimecode()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear {
            if let seq = targetSequence {
                timecodeText = seq.startTimecodeString ?? "01:00:00:00"
                displayFormat = seq.startTimecodeDisplayFormat ?? "NDF"
            }
        }
    }

    private func applyTimecode() {
        // Parse the timecode to get frame count
        let timebase = targetSequence?.timebase ?? appState.documents.first?.sequences.first?.timebase ?? 25
        guard let tc = Timecode.parse(timecodeText, timebase: timebase, dropFrame: displayFormat == "DF") else { return }

        if let targetID = appState.timecodeEditTargetSequenceID {
            appState.updateSequenceTimecode(sequenceID: targetID, newTC: tc.description, frame: tc.totalFrames, displayFormat: displayFormat)
        } else {
            appState.batchUpdateTimecodes(newTC: tc.description, frame: tc.totalFrames, displayFormat: displayFormat)
        }
    }
}

/// NSTextField's editor keeps its own string while focused, so update that editor
/// directly to make separators appear on each keystroke, including paste/delete.
private struct TimecodeTextField: NSViewRepresentable {
    @Binding var text: String
    let timebase: Int
    let dropFrame: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "HH:MM:SS:FF"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.setAccessibilityLabel("New Timecode")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimecodeTextField
        init(_ parent: TimecodeTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let raw = field.stringValue
            let editor = field.currentEditor()
            let selection = editor?.selectedRange ?? NSRange(location: raw.utf16.count, length: 0)
            let prefix = (raw as NSString).substring(to: min(selection.location, raw.utf16.count))
            let digitsBeforeCaret = prefix.filter { $0.isASCII && $0.isNumber }.count
            let formatted = TimecodeUtil.formatInput(raw)
            if raw != formatted {
                field.stringValue = formatted
                var caret = 0
                var digits = 0
                for character in formatted {
                    if digits == digitsBeforeCaret { break }
                    caret += 1
                    if character.isNumber { digits += 1 }
                }
                editor?.selectedRange = NSRange(location: caret, length: 0)
            }
            parent.text = formatted
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let tc = Timecode.parse(field.stringValue, timebase: parent.timebase,
                    dropFrame: parent.dropFrame) else { return }
            field.stringValue = tc.description
            parent.text = tc.description
        }
    }
}
