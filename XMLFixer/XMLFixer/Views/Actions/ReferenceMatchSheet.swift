import SwiftUI
import AppKit

struct ReferenceMatchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var referenceDirectory: URL? = nil
    @State private var scannedFiles: [String: [ScannedFile]] = [:]
    @State private var matches: [ReferenceMatch] = []
    @State private var isScanning = false
    @State private var isReadingTimecodes = false
    @State private var ignoreReferenceTimecode = false
    @State private var strictMode = true
    @State private var minChars: Double = 6
    @State private var extensionFilter = "mov,mp4"
    @State private var scanTask: Task<Void, Never>? = nil

    private var matchedCount: Int { matches.filter { $0.status == .matched || ($0.status == .multipleFound && $0.userConfirmed) }.count }
    private var multipleCount: Int { matches.filter { $0.status == .multipleFound && !$0.userConfirmed }.count }
    private var unmatchedCount: Int { matches.filter { $0.status == .unmatched }.count }
    private var hasAnyMatch: Bool { matches.contains { $0.selectedCandidateIndex != nil } }

    private var maxStemLength: Int {
        let maxLen = appState.documents.flatMap(\.sequences).map { ($0.name as NSString).deletingPathExtension.count }.max() ?? 20
        return max(maxLen, 3)
    }

    private var allSequences: [(id: UUID, name: String, parentDocumentID: UUID)] {
        appState.documents.flatMap { doc in
            doc.sequences.map { seq in (id: seq.id, name: seq.name, parentDocumentID: doc.id) }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Match Reference Files")
                .font(.headline)

            // Reference location
            HStack {
                Text("Reference Location:")
                    .foregroundStyle(.secondary)
                if let dir = referenceDirectory {
                    Text(dir.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(dir.path)
                } else {
                    Text("No folder selected")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Browse...") {
                    browseForFolder()
                }
            }

            // Matching options
            GroupBox("Matching Options") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Ignore reference timecode", isOn: $ignoreReferenceTimecode)
                        .toggleStyle(.checkbox)
                    Text(ignoreReferenceTimecode
                         ? "Reference frame zero starts at the first frame of each sequence."
                         : "Match embedded reference timecode. Frames outside its range are blank.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Strict (exact sequence name match)", isOn: $strictMode)
                        .toggleStyle(.checkbox)
                        .onChange(of: strictMode) { runMatching() }

                    if !strictMode {
                        HStack {
                            Text("Min matching chars:")
                            Slider(value: $minChars, in: 3...Double(maxStemLength), step: 1)
                                .onChange(of: minChars) { runMatching() }
                            Text("\(Int(minChars))")
                                .monospacedDigit()
                                .frame(width: 30)
                        }
                    }

                    HStack {
                        Text("Match extensions:")
                        TextField("e.g. mov,mp4", text: $extensionFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onChange(of: extensionFilter) { triggerRescan() }
                    }
                }
                .padding(4)
            }

            // Results
            if isScanning {
                ProgressView("Scanning directory...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isReadingTimecodes {
                ProgressView("Reading embedded timecodes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty && referenceDirectory != nil {
                Text("No sequences to match. Load XML files first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !matches.isEmpty {
                List {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        ReferenceMatchRow(match: match) { candidateIndex in
                            matches[index].selectedCandidateIndex = candidateIndex
                            matches[index].userConfirmed = true
                            matches[index].status = .matched
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                Text("Select a folder containing reference files to begin.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Summary
            if !matches.isEmpty {
                HStack(spacing: 16) {
                    Label("\(matchedCount) matched", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if multipleCount > 0 {
                        Label("\(multipleCount) need selection", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    if unmatchedCount > 0 {
                        Label("\(unmatchedCount) unmatched", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !matches.isEmpty {
                    Text("\(allSequences.count) sequences")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
                Button("Apply") {
                    let scopedMatches = matches.map { match in
                        var copy = match
                        copy.accessScopeURL = referenceDirectory
                        copy.ignoreReferenceTimecode = ignoreReferenceTimecode
                        return copy
                    }
                    appState.applyReferenceMatches(scopedMatches)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasAnyMatch)
            }
        }
        .padding()
        .frame(width: 850, height: 550)
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder containing reference video files"
        panel.prompt = "Select Folder"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            referenceDirectory = url
            triggerRescan()
        }
    }

    private func triggerRescan() {
        guard let directory = referenceDirectory else { return }
        scanTask?.cancel()
        scanTask = Task {
            isScanning = true
            let filter = extensionFilter.trimmingCharacters(in: .whitespaces)
            // FileScanner only takes a single extension filter, so we scan with no filter
            // and let matching handle extensions
            let files = await FileScanner.scan(directory: directory, extensionFilter: nil)

            // Filter to video extensions if specified
            if !filter.isEmpty {
                let exts = Set(filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                var filtered: [String: [ScannedFile]] = [:]
                for (key, value) in files {
                    let matching = value.filter { exts.contains($0.fileExtension.lowercased()) }
                    if !matching.isEmpty {
                        filtered[key] = matching
                    }
                }
                scannedFiles = filtered
            } else {
                scannedFiles = files
            }

            isScanning = false
            runMatching()
        }
    }

    private func runMatching() {
        guard !scannedFiles.isEmpty else {
            matches = []
            return
        }

        // Preserve user confirmations
        let previousConfirmations: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: matches
                .filter { $0.userConfirmed }
                .compactMap { match in
                    guard let idx = match.selectedCandidateIndex else { return nil }
                    return (match.sequenceID, idx)
                }
        )

        var newMatches = ReferenceMatchEngine.match(
            sequences: allSequences,
            against: scannedFiles,
            strictMode: strictMode,
            minChars: Int(minChars)
        )

        // Restore confirmations
        for i in newMatches.indices {
            if let prevIdx = previousConfirmations[newMatches[i].sequenceID],
               prevIdx < newMatches[i].candidates.count {
                newMatches[i].selectedCandidateIndex = prevIdx
                newMatches[i].userConfirmed = true
                newMatches[i].status = .matched
            }
            newMatches[i].accessScopeURL = referenceDirectory
        }

        matches = newMatches

        // Async read embedded timecodes from matched candidates
        readEmbeddedTimecodes()
    }

    private func readEmbeddedTimecodes() {
        guard !matches.isEmpty else { return }
        isReadingTimecodes = true
        let accessScopeURL = referenceDirectory

        // Capture snapshot: list of (matchIndex, candidateIndex, url) to read
        var jobs: [(candidateID: UUID, url: URL, timebase: Int)] = []
        for match in matches {
            for candidate in match.candidates {
                let timebase = appState.documents.flatMap(\.sequences).first { $0.id == match.sequenceID }?.timebase ?? 25
                jobs.append((candidateID: candidate.id, url: candidate.url, timebase: timebase))
            }
        }

        Task {
            let accessing = accessScopeURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if accessing {
                    accessScopeURL?.stopAccessingSecurityScopedResource()
                }
            }

            // Read all timecodes from snapshot
            var results: [(candidateID: UUID, tc: Timecode)] = []
            for job in jobs {
                if let tc = await AVAssetTimecodeReader.readStartTimecode(from: job.url, timebase: job.timebase) {
                    results.append((candidateID: job.candidateID, tc: tc))
                }
            }

            // Apply results back safely by ID lookup
            for result in results {
                for i in matches.indices {
                    if let j = matches[i].candidates.firstIndex(where: { $0.id == result.candidateID }) {
                        matches[i].candidates[j].embeddedTimecode = result.tc
                    }
                }
            }
            isReadingTimecodes = false
        }
    }
}

// MARK: - Row View

struct ReferenceMatchRow: View {
    let match: ReferenceMatch
    let onSelectCandidate: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(match.sequenceName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: 280, alignment: .leading)
                .help(match.sequenceName)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if match.candidates.count > 1 {
                Menu {
                    ForEach(Array(match.candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            onSelectCandidate(index)
                        } label: {
                            HStack {
                                if index == match.selectedCandidateIndex {
                                    Image(systemName: "checkmark")
                                }
                                VStack(alignment: .leading) {
                                    Text("\(candidate.displayFilename) — \(candidate.displaySize)")
                                    if let tc = candidate.embeddedTimecode {
                                        Text("TC: \(tc.description)")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedLabel)
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(match.userConfirmed ? .green : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(match.userConfirmed ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let url = match.selectedURL {
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    if let tc = match.selectedTimecode {
                        Text("TC: \(tc.description)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No match")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedLabel: String {
        if let idx = match.selectedCandidateIndex, idx < match.candidates.count {
            let c = match.candidates[idx]
            return "\(c.displayFilename) — \(c.displaySize)"
        }
        return "\(match.candidates.count) matches — pick one"
    }

    private var statusColor: Color {
        switch match.status {
        case .matched: return .green
        case .multipleFound: return match.userConfirmed ? .green : .orange
        case .unmatched: return .red
        }
    }
}
