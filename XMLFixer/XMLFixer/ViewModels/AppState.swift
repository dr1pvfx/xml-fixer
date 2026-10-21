import SwiftUI
import AVFoundation

@Observable
final class AppState {
    // MARK: - Documents
    var documents: [FCPXMLDocument] = []

    // MARK: - Derived media list
    var mediaReferences: [MediaReference] = []

    // MARK: - Selection
    var selectedDocumentIDs: Set<UUID> = []
    var selectedMediaIDs: Set<MediaReference.ID> = []

    // MARK: - UI state
    var isShowingExportSheet = false
    var isShowingImportPanel = false
    var exportOptions = ExportOptions()
    var statusMessage = ""
    var isProcessing = false
    private var statusClearTask: DispatchWorkItem?

    // MARK: - Confirmation alerts
    var showRemoveMediaAlert = false
    var showStripAudioAlert = false
    var showRenameTimelinesAlert = false
    var showInjectReelNamesAlert = false

    // MARK: - Edit / Batch Rename state
    var editingMediaID: MediaReference.ID? = nil
    var isShowingBatchRename = false

    // MARK: - Sidebar sequence rename state
    var sidebarEditingSequenceID: SequenceInfo.ID? = nil
    var sidebarEditName: String = ""
    var isShowingBatchTimelineRename = false

    // MARK: - Timeline state
    var selectedSequenceID: SequenceInfo.ID? = nil
    var currentTimelineData: TimelineData? = nil
    var selectedTimelineClip: TimelineClip? = nil

    // MARK: - Sources Export state
    var sourcesExportOptions = SourcesExportOptions()
    var isShowingSourcesExportSheet = false

    // MARK: - Scale Calculator state
    var isShowingScaleCalculator = false

    // MARK: - Relink state
    var isShowingRelinkSheet = false
    var isShowingCollectSheet = false

    // MARK: - Denest state
    var showDenestAlert = false

    // MARK: - Reference Match State
    var referenceMatches: [UUID: ReferenceMatch] = [:]  // keyed by SequenceInfo.ID
    var isShowingReferenceMatchSheet = false

    // MARK: - Timecode Edit State
    var isShowingTimecodeEditSheet = false
    var timecodeEditTargetSequenceID: UUID? = nil  // nil = batch mode

    // MARK: - Playback State
    var playheadFrame: Int = 0
    var playbackCoordinator: PlaybackCoordinator? = nil
    var isPlayerEmbedded: Bool = true
    var showSourceTCOverlay: Bool = true

    // MARK: - Undo
    private struct UndoSnapshot {
        let description: String
        let documentSnapshots: [(documentID: UUID, xmlData: Data, sequences: [SequenceInfo], isDirty: Bool)]
    }
    private var undoStack: [UndoSnapshot] = []
    private let maxUndoLevels = 20
    var canUndo: Bool { !undoStack.isEmpty }
    var undoDescription: String? { undoStack.last?.description }

    // MARK: - Filter/search
    var mediaSearchText = ""
    var mediaFilterPattern = ""
    var groupByExtension = false

    // MARK: - Computed

    var filteredMedia: [MediaReference] {
        var result = mediaReferences

        // Text search
        if !mediaSearchText.isEmpty {
            result = result.filter {
                $0.filename.localizedCaseInsensitiveContains(mediaSearchText)
            }
        }

        // Glob pattern filter
        if !mediaFilterPattern.isEmpty {
            let patterns = mediaFilterPattern
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            if !patterns.isEmpty {
                result = result.filter { media in
                    let name = media.filename.lowercased()
                    return patterns.contains { pattern in
                        Self.matchesGlob(name, pattern: pattern)
                    }
                }
            }
        }

        return result
    }

    var selectedMediaCount: Int { selectedMediaIDs.count }
    var hasDocuments: Bool { !documents.isEmpty }

    var selectedMediaFilenames: Set<String> {
        Set(mediaReferences.filter { selectedMediaIDs.contains($0.id) }.map(\.filename))
    }

    var editingMedia: MediaReference? {
        guard let id = editingMediaID else { return nil }
        return mediaReferences.first { $0.id == id }
    }

    var denestPreview: (sequenceCount: Int, documentCount: Int) {
        var totalNested = 0
        var affectedDocs = 0
        for doc in documents {
            let count = doc.sequences.reduce(0) { $0 + $1.nestedSequenceCount }
            if count > 0 {
                totalNested += count
                affectedDocs += 1
            }
        }
        return (totalNested, affectedDocs)
    }

    var hasNestedSequences: Bool {
        documents.flatMap(\.sequences).contains { $0.hasNestedSequences }
    }

    /// Preview counts for remove-media confirmation
    var removeMediaPreview: (mediaCount: Int, clipCount: Int, docCount: Int) {
        let filenames = Set(
            mediaReferences
                .filter { selectedMediaIDs.contains($0.id) }
                .map { $0.filename }
        )
        let counts = FCPXMLMutator.countClipitemsToRemove(matching: filenames, in: documents)
        return (filenames.count, counts.clipCount, counts.documentCount)
    }

    /// Preview counts for inject reel names confirmation
    var injectReelNamesPreview: (fileCount: Int, docCount: Int) {
        let counts = ReelMetadataRepairer.countRepairableFiles(in: documents)
        return (counts.fileCount, counts.documentCount)
    }

    /// Detailed preview for inject reel names — returns filename/reelName pairs
    var injectReelNamesDetailedPreview: [(filename: String, reelName: String)] {
        var results: [(filename: String, reelName: String)] = []
        let pattern = ReelMetadataRepairer.reelPattern

        for doc in documents {
            guard let root = doc.xmlDocument.rootElement() else { continue }
            var processedIDs: Set<String> = []

            guard let fileNodes = try? root.nodes(forXPath: "//file[@id]") else { continue }

            for node in fileNodes {
                guard let fileElem = node as? XMLElement,
                      let fileID = fileElem.attribute(forName: "id")?.stringValue,
                      !processedIDs.contains(fileID)
                else { continue }

                processedIDs.insert(fileID)

                guard let nameText = (try? fileElem.nodes(forXPath: "name"))?.first?.stringValue,
                      nameText.hasPrefix("A_")
                else { continue }

                guard let timecodeNode = (try? fileElem.nodes(forXPath: "timecode"))?.first as? XMLElement
                else { continue }

                let existingReel = try? timecodeNode.nodes(forXPath: "reel")
                if let reels = existingReel, !reels.isEmpty { continue }

                let range = NSRange(nameText.startIndex..., in: nameText)
                guard let match = pattern.firstMatch(in: nameText, range: range),
                      let group1Range = Range(match.range(at: 1), in: nameText),
                      let group2Range = Range(match.range(at: 2), in: nameText)
                else { continue }

                let reelName = "\(nameText[group1Range])_\(nameText[group2Range])"
                results.append((filename: nameText, reelName: reelName))
            }
        }

        return results
    }

    // MARK: - Actions

    func importFiles(urls: [URL]) {
        let existingURLs = Set(documents.map(\.sourceURL))
        guard !urls.isEmpty else { return }

        isProcessing = true

        // Parse on a background queue to avoid freezing the UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var parsed: [FCPXMLDocument] = []
            var lastError: String?

            let scopedURLs = urls.map { url in
                (url: url, isAccessing: url.startAccessingSecurityScopedResource())
            }
            defer {
                for scoped in scopedURLs where scoped.isAccessing {
                    scoped.url.stopAccessingSecurityScopedResource()
                }
            }

            let resolvedURLs = Self.resolveXMLURLs(from: urls)
            let xmlURLs = resolvedURLs.filter { !existingURLs.contains($0) }

            for url in xmlURLs {
                do {
                    let doc = try FCPXMLParser.parse(url: url)
                    parsed.append(doc)
                } catch {
                    lastError = "Failed to parse \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.documents.append(contentsOf: parsed)
                self.refreshMediaReferences()
                self.isProcessing = false
                if xmlURLs.isEmpty {
                    self.setStatus("No new XML files found")
                } else if let lastError {
                    self.setStatus(lastError)
                } else {
                    self.setStatus("Loaded \(parsed.count) XML\(parsed.count == 1 ? "" : "s")")
                }
            }
        }
    }

    func removeDocument(_ id: UUID) {
        documents.removeAll { $0.id == id }
        refreshMediaReferences()
    }

    func removeSelectedMedia() {
        pushUndo("Remove media")
        let selectedFilenames = Set(
            mediaReferences
                .filter { selectedMediaIDs.contains($0.id) }
                .map { $0.filename }
        )

        var totalRemoved = 0
        var affectedDocs = 0

        for doc in documents {
            let fileMap = FCPXMLMutator.buildFileMap(from: doc.xmlDocument)
            let removed = FCPXMLMutator.removeClipitems(
                matching: selectedFilenames,
                in: doc,
                fileMap: fileMap
            )
            if removed > 0 {
                totalRemoved += removed
                affectedDocs += 1
            }
        }

        selectedMediaIDs.removeAll()
        refreshMediaReferences()
        setStatus("Removed \(totalRemoved) clips from \(affectedDocs) XMLs")
    }

    func removeAllAudioTracks() {
        pushUndo("Strip audio")
        var totalRemoved = 0
        for doc in documents {
            totalRemoved += FCPXMLMutator.removeAllAudioTracks(in: doc)
        }
        refreshMediaReferences()
        setStatus("Stripped \(totalRemoved) audio tracks from \(documents.count) XMLs")
    }

    func renameTimelines() {
        pushUndo("Rename timelines")
        var totalRenamed = 0
        for doc in documents {
            totalRenamed += FCPXMLMutator.renameSequences(
                in: doc,
                to: doc.filenameWithoutExtension
            )
        }
        for i in documents.indices {
            for j in documents[i].sequences.indices {
                documents[i].sequences[j].name = documents[i].filenameWithoutExtension
            }
        }
        setStatus("Renamed \(totalRenamed) sequences")
    }

    func renameSequence(sequenceID: SequenceInfo.ID, to newName: String) {
        pushUndo("Rename sequence")
        for doc in documents {
            if let seqIndex = doc.sequences.firstIndex(where: { $0.id == sequenceID }) {
                if let elemID = doc.sequences[seqIndex].sequenceElementID {
                    let success = FCPXMLMutator.renameSequence(in: doc, sequenceElementID: elemID, to: newName)
                    if success {
                        doc.sequences[seqIndex].name = newName
                        setStatus("Renamed sequence to '\(newName)'")
                        if selectedSequenceID == sequenceID {
                            refreshTimelineData()
                        }
                    }
                }
                return
            }
        }
    }

    func batchRenameTimelines(operation: BatchOperation, documentIDs: Set<UUID>) {
        pushUndo("Batch rename timelines")
        var totalRenamed = 0
        let targetDocs = documentIDs.isEmpty ? documents : documents.filter { documentIDs.contains($0.id) }
        for doc in targetDocs {
            for i in doc.sequences.indices {
                let oldName = doc.sequences[i].name
                let newName = operation.apply(to: oldName)
                guard newName != oldName, let elemID = doc.sequences[i].sequenceElementID else { continue }
                let success = FCPXMLMutator.renameSequence(in: doc, sequenceElementID: elemID, to: newName)
                if success {
                    doc.sequences[i].name = newName
                    totalRenamed += 1
                }
            }
        }
        refreshTimelineData()
        setStatus("Renamed \(totalRenamed) timelines")
    }

    func injectReelNames() {
        pushUndo("Inject reels")
        var totalRepaired = 0
        var affectedDocs = 0
        for doc in documents {
            let repaired = ReelMetadataRepairer.repairReelMetadata(in: doc.xmlDocument)
            if repaired > 0 {
                doc.isDirty = true
                totalRepaired += repaired
                affectedDocs += 1
            }
        }
        refreshMediaReferences()
        setStatus("Injected reel names for \(totalRepaired) files across \(affectedDocs) XMLs")
    }

    func exportAll() {
        isProcessing = true
        let docs = documents
        let options = exportOptions

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = ExportService.exportAll(documents: docs, options: options)
            let successCount = results.filter(\.success).count
            let failedNames = results.filter { !$0.success }.map { $0.outputURL.lastPathComponent }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                if failedNames.isEmpty {
                    self.setStatus("Exported \(successCount) files")
                } else {
                    self.setStatus("Exported \(successCount)/\(results.count) — failed: \(failedNames.joined(separator: ", "))")
                }
            }
        }
    }

    func exportCSV() {
        let csv = CSVExporter.export(mediaReferences: filteredMedia)
        CSVExporter.showSavePanelAndExport(csv: csv) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self?.setStatus("Exported CSV to \(url.lastPathComponent)")
                case .failure(let error):
                    self?.setStatus("CSV export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func selectAllVisibleMedia() {
        selectedMediaIDs = Set(filteredMedia.map(\.id))
    }

    func deselectAllMedia() {
        selectedMediaIDs.removeAll()
    }

    func updateMediaFilename(mediaID: UUID, newFilename: String) {
        pushUndo("Rename file")
        guard let media = mediaReferences.first(where: { $0.id == mediaID }) else { return }
        let updated = FCPXMLMutator.updateFilename(from: media.filename, to: newFilename, in: documents)
        if updated > 0 {
            refreshMediaReferences()
            setStatus("Renamed '\(media.filename)' → '\(newFilename)' in \(updated) locations")
        }
    }

    func updateMediaReelName(mediaID: UUID, newReel: String) {
        pushUndo("Update reel")
        guard let media = mediaReferences.first(where: { $0.id == mediaID }) else { return }
        let updated = FCPXMLMutator.updateReelName(for: media.filename, to: newReel, in: documents)
        if updated > 0 {
            refreshMediaReferences()
            setStatus("Set reel '\(newReel)' on '\(media.filename)' in \(updated) locations")
        }
    }

    func updateMediaPath(mediaID: UUID, newPath: String) {
        pushUndo("Update path")
        guard let media = mediaReferences.first(where: { $0.id == mediaID }) else { return }
        let updated = FCPXMLMutator.updatePathURL(for: media.filename, to: newPath, in: documents)
        if updated > 0 {
            refreshMediaReferences()
            setStatus("Updated path for '\(media.filename)' in \(updated) locations")
        }
    }

    func batchRename(field: BatchField, operation: BatchOperation, selectedIDs: Set<UUID>) {
        pushUndo("Batch rename")
        let targets = mediaReferences.filter { selectedIDs.contains($0.id) }
        var totalUpdated = 0

        for media in targets {
            let oldValue: String
            switch field {
            case .filename: oldValue = media.filename
            case .reelName: oldValue = media.reelName ?? ""
            case .pathURL: oldValue = media.pathURL ?? ""
            }

            let newValue = operation.apply(to: oldValue)
            guard newValue != oldValue else { continue }

            switch field {
            case .filename:
                totalUpdated += FCPXMLMutator.updateFilename(from: oldValue, to: newValue, in: documents)
            case .reelName:
                totalUpdated += FCPXMLMutator.updateReelName(for: media.filename, to: newValue, in: documents)
            case .pathURL:
                totalUpdated += FCPXMLMutator.updatePathURL(for: media.filename, to: newValue, in: documents)
            }
        }

        refreshMediaReferences()
        setStatus("Batch renamed \(totalUpdated) items")
    }

    func applyRelink(_ matches: [RelinkMatch]) {
        pushUndo("Relink paths")
        var totalUpdated = 0
        for match in matches {
            guard let idx = match.selectedCandidateIndex, idx < match.candidates.count else { continue }
            let candidate = match.candidates[idx]
            // Convert file URL to the file:// URL string format FCP XML expects
            let fileURL = URL(fileURLWithPath: candidate.url.path)
            let newPath = fileURL.absoluteString
            totalUpdated += FCPXMLMutator.updatePathURL(
                for: match.mediaFilename, to: newPath, in: documents
            )
        }
        refreshMediaReferences()
        setStatus("Relinked \(totalUpdated) file paths")
    }

    func updateEffectParameter(clipElementID: String, filterIndex: Int, parameterID: String, newValue: String) {
        pushUndo("Edit effect")
        for doc in documents {
            if FCPXMLMutator.updateEffectParameter(
                clipElementID: clipElementID,
                filterIndex: filterIndex,
                parameterID: parameterID,
                newValue: newValue,
                in: doc
            ) {
                refreshTimelineData()
                // Update selectedTimelineClip to reflect changes
                if let timeline = currentTimelineData {
                    let allClips = timeline.videoTracks.flatMap(\.clips) + timeline.audioTracks.flatMap(\.clips)
                    selectedTimelineClip = allClips.first { $0.clipElementID == clipElementID }
                }
                setStatus("Updated effect parameter")
                return
            }
        }
    }

    func removeEffect(clipElementID: String, filterIndex: Int) {
        pushUndo("Remove effect")
        for doc in documents {
            if FCPXMLMutator.removeEffect(
                clipElementID: clipElementID,
                filterIndex: filterIndex,
                in: doc
            ) {
                refreshTimelineData()
                // Update selectedTimelineClip to reflect changes
                if let timeline = currentTimelineData {
                    let allClips = timeline.videoTracks.flatMap(\.clips) + timeline.audioTracks.flatMap(\.clips)
                    selectedTimelineClip = allClips.first { $0.clipElementID == clipElementID }
                }
                setStatus("Removed effect")
                return
            }
        }
    }

    func refreshTimelineData() {
        defer { refreshPlaybackAlignment() }
        guard let seqID = selectedSequenceID else {
            currentTimelineData = nil
            return
        }

        for doc in documents {
            if let seq = doc.sequences.first(where: { $0.id == seqID }) {
                currentTimelineData = TimelineExtractor.extractTimeline(for: seq, from: doc)
                return
            }
        }
        currentTimelineData = nil
    }

    func exportSourcesSequence() {
        isProcessing = true
        let opts = sourcesExportOptions
        let docs = documents

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try SourcesSequenceBuilder.export(documents: docs, options: opts)
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    self?.setStatus("Exported Sources Sequence to \(url.lastPathComponent)")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    self?.setStatus("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func denestAllSequences() {
        pushUndo("Denest sequences")
        var totalDenested = 0
        var affectedDocs = 0
        for doc in documents {
            let count = FCPXMLMutator.denestSequences(in: doc)
            if count > 0 {
                totalDenested += count
                affectedDocs += 1
            }
        }
        // Re-parse sequences to update nested counts
        for doc in documents {
            if let _ = doc.xmlDocument.rootElement(),
               let _ = try? doc.xmlDocument.rootElement()?.nodes(forXPath: "//sequence[@id]") {
                for i in doc.sequences.indices {
                    doc.sequences[i].hasNestedSequences = false
                    doc.sequences[i].nestedSequenceCount = 0
                }
            }
        }
        refreshMediaReferences()
        setStatus("Denested \(totalDenested) sequences in \(affectedDocs) XMLs")
    }

    // MARK: - Timecode Edit Actions

    func updateSequenceTimecode(sequenceID: UUID, newTC: String, frame: Int, displayFormat: String) {
        pushUndo("Edit start timecode")
        for doc in documents {
            if let seq = doc.sequences.first(where: { $0.id == sequenceID }),
               let elemID = seq.sequenceElementID {
                if FCPXMLMutator.updateSequenceTimecode(
                    in: doc, sequenceElementID: elemID,
                    timecodeString: newTC, frame: frame,
                    displayFormat: displayFormat
                ) {
                    // Update local SequenceInfo
                    if let idx = doc.sequences.firstIndex(where: { $0.id == sequenceID }) {
                        doc.sequences[idx].startTimecodeString = newTC
                        doc.sequences[idx].startTimecodeFrame = frame
                        doc.sequences[idx].startTimecodeDisplayFormat = displayFormat
                    }
                    refreshTimelineData()
                    setStatus("Updated start TC to \(newTC)")
                }
                return
            }
        }
    }

    func batchUpdateTimecodes(newTC: String, frame: Int, displayFormat: String) {
        pushUndo("Batch edit start timecode")
        var count = 0
        for doc in documents {
            for seq in doc.sequences {
                guard let elemID = seq.sequenceElementID,
                      let tc = Timecode.parse(newTC, timebase: seq.timebase ?? 25, dropFrame: displayFormat == "DF") else { continue }
                let frame = tc.totalFrames
                if FCPXMLMutator.updateSequenceTimecode(
                    in: doc, sequenceElementID: elemID,
                    timecodeString: newTC, frame: frame,
                    displayFormat: displayFormat
                ) {
                    if let idx = doc.sequences.firstIndex(where: { $0.id == seq.id }) {
                        doc.sequences[idx].startTimecodeString = newTC
                        doc.sequences[idx].startTimecodeFrame = frame
                        doc.sequences[idx].startTimecodeDisplayFormat = displayFormat
                    }
                    count += 1
                }
            }
        }
        refreshTimelineData()
        setStatus("Updated start TC on \(count) sequences")
    }

    // MARK: - Reference Match Actions

    func applyReferenceMatches(_ matches: [ReferenceMatch]) {
        for match in matches where match.selectedCandidateIndex != nil {
            referenceMatches[match.sequenceID] = match
        }
        let count = matches.filter { $0.selectedCandidateIndex != nil }.count
        setStatus("Matched \(count) reference files")
        autoLoadReferencePlayer()
    }

    func setIgnoreReferenceTimecode(_ ignore: Bool) {
        guard let id = selectedSequenceID, referenceMatches[id] != nil else { return }
        referenceMatches[id]?.ignoreReferenceTimecode = ignore
        refreshPlaybackAlignment()
    }

    private func refreshPlaybackAlignment() {
        guard let timeline = currentTimelineData,
              let match = referenceMatches[timeline.sequenceID] else { return }
        playbackCoordinator?.updateAlignment(
            timelineStartTC: Timecode.fromFrames(timeline.startTimecodeFrame, timebase: timeline.timebase,
                dropFrame: documents.flatMap(\.sequences).first { $0.id == timeline.sequenceID }?.startTimecodeDisplayFormat == "DF"),
            referenceStartTC: match.selectedTimecode,
            ignoreReferenceTimecode: match.ignoreReferenceTimecode,
            timelineFrame: playheadFrame
        )
    }

    func matchTimecodeToReference(sequenceID: UUID) {
        guard let match = referenceMatches[sequenceID],
              let tc = match.selectedTimecode else {
            setStatus("No reference timecode available")
            return
        }
        updateSequenceTimecode(
            sequenceID: sequenceID,
            newTC: tc.description,
            frame: tc.totalFrames,
            displayFormat: tc.isDropFrame ? "DF" : "NDF"
        )
    }

    // MARK: - Source TC Overlay

    struct SourceTCEntry: Identifiable {
        let id: String  // track label
        let trackLabel: String
        let timecode: String
        let clipName: String
    }

    /// Timeline record TC: start timecode + playhead position
    var currentRecordTimecode: String {
        guard let timeline = currentTimelineData else { return "00:00:00:00" }
        let startFrame = timeline.startTimecodeFrame
        let isDF = documents.flatMap(\.sequences).first { $0.id == timeline.sequenceID }?.startTimecodeDisplayFormat == "DF"
        let tc = Timecode.fromFrames(startFrame + playheadFrame, timebase: timeline.timebase, dropFrame: isDF)
        return tc.description
    }

    var sourceTimecodesAtPlayhead: [SourceTCEntry] {
        guard let timeline = currentTimelineData else { return [] }
        let frame = playheadFrame
        var results: [SourceTCEntry] = []

        for track in timeline.videoTracks.sorted(by: { $0.index > $1.index }) {
            if let clip = track.clips.first(where: { frame >= $0.startFrame && frame < $0.endFrame }) {
                let sourceFrame = clip.fileStartTimecodeFrame + clip.sourceInFrame + (frame - clip.startFrame)
                let tc = Timecode.fromFrames(sourceFrame, timebase: timeline.timebase)
                results.append(SourceTCEntry(
                    id: track.label,
                    trackLabel: track.label,
                    timecode: tc.description,
                    clipName: clip.clipName
                ))
            }
        }
        return results
    }

    // MARK: - Playhead & Player Actions

    func seekPlayhead(toFrame frame: Int) {
        playheadFrame = max(0, frame)
        playbackCoordinator?.seekToTimelineFrame(frame)
    }

    func openVideoPlayer(for sequenceID: UUID) {
        loadCoordinatorForSequence(sequenceID)
        if !isPlayerEmbedded {
            VideoPlayerWindow.shared.open(appState: self)
        }
    }

    func closeVideoPlayer() {
        VideoPlayerWindow.shared.close()
        playbackCoordinator = nil
    }

    func autoLoadReferencePlayer() {
        guard let seqID = selectedSequenceID else {
            playbackCoordinator = nil
            return
        }

        if referenceMatches[seqID]?.selectedURL != nil {
            loadCoordinatorForSequence(seqID)
        } else {
            playbackCoordinator = nil
        }
    }

    func popOutPlayer() {
        VideoPlayerWindow.shared.open(appState: self)
        isPlayerEmbedded = false
    }

    func embedPlayer() {
        isPlayerEmbedded = true
        VideoPlayerWindow.shared.close()
    }

    private func loadCoordinatorForSequence(_ sequenceID: UUID) {
        guard let match = referenceMatches[sequenceID],
              let url = match.selectedURL else { return }

        let seq = documents.flatMap(\.sequences).first { $0.id == sequenceID }
        let timebase = seq?.timebase ?? 25
        let startTCFrame = seq?.startTimecodeFrame ?? 0
        let isDF = seq?.startTimecodeDisplayFormat == "DF"
        let startTC = Timecode.fromFrames(startTCFrame, timebase: timebase, dropFrame: isDF)
        let refTC = match.selectedTimecode
        let totalFrames = currentTimelineData?.totalDurationFrames ?? 0

        let coordinator = PlaybackCoordinator(
            referenceURL: url,
            accessScopeURL: match.accessScopeURL,
            timelineStartTC: startTC,
            referenceStartTC: refTC,
            timebase: timebase,
            totalDurationFrames: totalFrames,
            ntsc: seq?.ntsc ?? false,
            ignoreReferenceTimecode: match.ignoreReferenceTimecode
        )

        coordinator.onPlayheadFrameChanged = { [weak self] frame in
            self?.playheadFrame = frame
        }

        self.playbackCoordinator = coordinator
        coordinator.seekToTimelineFrame(playheadFrame)
    }

    // MARK: - Undo Actions

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        for docSnap in snapshot.documentSnapshots {
            guard let doc = documents.first(where: { $0.id == docSnap.documentID }) else { continue }
            // Replace the XML document's root with the snapshot
            if let restoredDoc = try? XMLDocument(data: docSnap.xmlData, options: []),
               let restoredRoot = restoredDoc.rootElement()?.copy() as? XMLElement {
                doc.xmlDocument.setRootElement(restoredRoot)
            }
            doc.sequences = docSnap.sequences
            doc.isDirty = docSnap.isDirty
        }
        refreshMediaReferences()
        setStatus("Undo: \(snapshot.description)")
    }

    private func pushUndo(_ description: String) {
        let snapshots = documents.map { doc in
            (
                documentID: doc.id,
                xmlData: doc.xmlDocument.xmlData(options: []),
                sequences: doc.sequences,
                isDirty: doc.isDirty
            )
        }
        undoStack.append(UndoSnapshot(description: description, documentSnapshots: snapshots))
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
    }

    // MARK: - Private

    private static func resolveXMLURLs(from urls: [URL]) -> [URL] {
        var xmlURLs: [URL] = []
        let fileManager = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // Recursively find all .xml files in the directory
                if let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.pathExtension.lowercased() == "xml" {
                            xmlURLs.append(fileURL)
                        }
                    }
                }
            } else if url.pathExtension.lowercased() == "xml" {
                xmlURLs.append(url)
            }
        }

        return xmlURLs
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.statusMessage = ""
        }
        statusClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    private func refreshMediaReferences() {
        mediaReferences = FCPXMLParser.extractMediaReferences(from: documents)
        // Clean up selection — remove IDs that no longer exist
        let validIDs = Set(mediaReferences.map(\.id))
        selectedMediaIDs.formIntersection(validIDs)
        // Also re-parse sequences (track counts may have changed) and refresh timeline
        refreshSequenceInfo()
        refreshTimelineData()
    }

    /// Simple glob pattern matching supporting * and ? wildcards.
    /// * matches zero or more characters, ? matches exactly one character.
    private static func matchesGlob(_ string: String, pattern: String) -> Bool {
        let s = Array(string)
        let p = Array(pattern)
        var si = 0, pi = 0
        var starSI = -1, starPI = -1

        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                si += 1
                pi += 1
            } else if pi < p.count && p[pi] == "*" {
                starPI = pi
                starSI = si
                pi += 1
            } else if starPI >= 0 {
                pi = starPI + 1
                starSI += 1
                si = starSI
            } else {
                return false
            }
        }

        while pi < p.count && p[pi] == "*" {
            pi += 1
        }

        return pi == p.count
    }

    private func refreshSequenceInfo() {
        for doc in documents {
            guard let root = doc.xmlDocument.rootElement() else { continue }
            guard let seqNodes = try? root.nodes(forXPath: "//sequence[@id]") else { continue }
            var updatedSequences: [SequenceInfo] = []
            for node in seqNodes {
                guard let elem = node as? XMLElement,
                      let seqID = elem.attribute(forName: "id")?.stringValue else { continue }
                let name = (try? elem.nodes(forXPath: "name"))?.first?.stringValue ?? "Untitled"
                let videoTracks = (try? elem.nodes(forXPath: "media/video/track"))?.count ?? 0
                let audioTracks = (try? elem.nodes(forXPath: "media/audio/track"))?.count ?? 0
                let nestedCount = (try? elem.nodes(forXPath: ".//clipitem/sequence"))?.count ?? 0
                let existing = doc.sequences.first(where: { $0.sequenceElementID == seqID })

                // Re-read timecode fields from the XML (may have been mutated)
                let startTCString = (try? elem.nodes(forXPath: "timecode/string"))?.first?.stringValue
                var startTCFrame: Int? = (try? elem.nodes(forXPath: "timecode/frame"))?.first?.stringValue.flatMap { Int($0) }
                let startTCDisplayFormat = (try? elem.nodes(forXPath: "timecode/displayformat"))?.first?.stringValue
                let ntsc = (try? elem.nodes(forXPath: "rate/ntsc"))?.first?.stringValue?.uppercased() == "TRUE"

                // If <frame> element is missing but <string> is present, parse TC string
                let seqTimebase = (try? elem.nodes(forXPath: "rate/timebase"))?.first?.stringValue.flatMap { Int($0) } ?? 25
                if (startTCFrame == nil || startTCFrame == 0), let tcStr = startTCString,
                   let parsed = Timecode.parse(tcStr, timebase: seqTimebase, dropFrame: startTCDisplayFormat == "DF") {
                    startTCFrame = parsed.totalFrames
                }

                updatedSequences.append(SequenceInfo(
                    id: existing?.id ?? UUID(),
                    sequenceElementID: seqID,
                    name: name,
                    duration: existing?.duration,
                    timebase: existing?.timebase,
                    videoTrackCount: videoTracks,
                    audioTrackCount: audioTracks,
                    parentDocumentID: doc.id,
                    fps: existing?.fps,
                    audioChannelInfo: existing?.audioChannelInfo,
                    hasNestedSequences: nestedCount > 0,
                    nestedSequenceCount: nestedCount,
                    startTimecodeString: startTCString,
                    startTimecodeFrame: startTCFrame,
                    startTimecodeDisplayFormat: startTCDisplayFormat,
                    ntsc: ntsc
                ))
            }
            doc.sequences = updatedSequences
        }
    }
}

// MARK: - Playback Coordinator

@Observable
class PlaybackCoordinator {
    let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var currentTimecodeString = "00:00:00:00"
    private(set) var scrubPosition: Double = 0
    private(set) var timelineFrame = 0
    private(set) var referenceDuration: CMTime?
    private(set) var isSeeking = false

    private let accessScopeURL: URL?
    private let isAccessingSecurityScopedURL: Bool
    private var timelineStartTC: Timecode
    private var referenceStartTC: Timecode?
    private var referenceFrameDuration: CMTime?
    private var ignoreReferenceTimecode: Bool
    private let timebase: Int
    private let totalDurationFrames: Int
    private let ntsc: Bool
    private var playbackTimer: Timer?
    private var playbackStartTime: TimeInterval = 0
    private var playbackStartFrame = 0
    private var seekGeneration = 0
    private var durationTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?

    var onPlayheadFrameChanged: ((Int) -> Void)?

    var frameDuration: CMTime {
        CMTime(value: ntsc ? 1001 : 1, timescale: CMTimeScale(timebase * (ntsc ? 1000 : 1)))
    }

    /// Signed media time: never clamp this value to the first/last reference image.
    func referenceTime(forTimelineFrame frame: Int) -> CMTime? {
        let relative = CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frame))
        if ignoreReferenceTimecode { return relative }
        guard let referenceStartTC else { return nil }
        let timelineStart = CMTimeMultiply(frameDuration, multiplier: Int32(clamping: timelineStartTC.totalFrames))
        let refDuration = referenceFrameDuration ?? CMTime(value: ntsc ? 1001 : 1,
            timescale: CMTimeScale(referenceStartTC.timebase * (ntsc ? 1000 : 1)))
        let refStart = CMTimeMultiply(refDuration, multiplier: Int32(clamping: referenceStartTC.totalFrames))
        return timelineStart + relative - refStart
    }

    var isWithinReferenceRange: Bool {
        guard let time = referenceTime(forTimelineFrame: timelineFrame), let referenceDuration else { return false }
        return time >= .zero && time < referenceDuration
            && timelineFrame >= 0 && timelineFrame < totalDurationFrames
    }

    var referenceStatusMessage: String? {
        if !ignoreReferenceTimecode && referenceStartTC == nil {
            return "No reference timecode — enable Ignore reference timecode to align first frames"
        }
        guard referenceDuration != nil else { return "Loading reference…" }
        if !isWithinReferenceRange { return "Out of reference range" }
        return isSeeking ? "Loading reference…" : nil
    }

    init(referenceURL: URL, accessScopeURL: URL? = nil, timelineStartTC: Timecode,
         referenceStartTC: Timecode?, timebase: Int, totalDurationFrames: Int,
         ntsc: Bool = false, ignoreReferenceTimecode: Bool = false) {
        self.accessScopeURL = accessScopeURL
        self.isAccessingSecurityScopedURL = accessScopeURL?.startAccessingSecurityScopedResource() ?? false
        self.timelineStartTC = timelineStartTC
        self.referenceStartTC = referenceStartTC
        self.ignoreReferenceTimecode = ignoreReferenceTimecode
        self.timebase = max(1, timebase)
        self.totalDurationFrames = totalDurationFrames
        self.ntsc = ntsc

        let asset = AVURLAsset(url: referenceURL)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] _ in
                self?.player.pause()
            }
        durationTask = Task { [weak self] in
            guard var duration = try? await asset.load(.duration), duration.isNumeric else { return }
            if let video = try? await asset.loadTracks(withMediaType: .video).first,
               let range = try? await video.load(.timeRange) {
                duration = CMTimeRangeGetEnd(range)
            }
            var tcFrameDuration: CMTime?
            if let track = try? await asset.loadTracks(withMediaType: .timecode).first,
               let format = try? await track.load(.formatDescriptions).first {
                let value = CMTimeCodeFormatDescriptionGetFrameDuration(format)
                if value.isNumeric && value > .zero { tcFrameDuration = value }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.referenceFrameDuration = tcFrameDuration
                self.referenceDuration = duration
                self.seekToTimelineFrame(self.timelineFrame)
            }
        }
    }

    func updateAlignment(timelineStartTC: Timecode, referenceStartTC: Timecode?,
                         ignoreReferenceTimecode: Bool, timelineFrame: Int) {
        self.timelineStartTC = timelineStartTC
        self.referenceStartTC = referenceStartTC
        self.ignoreReferenceTimecode = ignoreReferenceTimecode
        seekToTimelineFrame(timelineFrame)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
            return
        }
        guard totalDurationFrames > 0 else { return }
        if timelineFrame >= totalDurationFrames - 1 { seekToTimelineFrame(0) }
        isPlaying = true
        playbackStartFrame = timelineFrame
        playbackStartTime = ProcessInfo.processInfo.systemUptime
        synchronizePlayer()
        // The sequence clock keeps running through gaps before and after the reference.
        let timer = Timer(timeInterval: frameDuration.seconds, repeats: true) { [weak self] _ in
            self?.advancePlayback()
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pause() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        player.pause()
        isPlaying = false
    }

    func stepForward() {
        pause()
        seekToTimelineFrame(timelineFrame + 1)
    }

    func stepBackward() {
        pause()
        seekToTimelineFrame(timelineFrame - 1)
    }

    func seekToTimelineFrame(_ frame: Int) {
        timelineFrame = min(max(0, frame), max(0, totalDurationFrames - 1))
        playbackStartFrame = timelineFrame
        playbackStartTime = ProcessInfo.processInfo.systemUptime
        updateTimecodeDisplay()
        synchronizePlayer()
    }

    func scrubToPosition(_ position: Double) {
        seekToTimelineFrame(Int((Double(max(0, totalDurationFrames - 1)) * min(1, max(0, position))).rounded()))
    }

    private func advancePlayback() {
        guard !isSeeking else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - playbackStartTime
        let next = playbackStartFrame + Int((elapsed / frameDuration.seconds).rounded(.down))
        let wasInRange = isWithinReferenceRange
        timelineFrame = min(next, max(0, totalDurationFrames - 1))
        updateTimecodeDisplay()
        if wasInRange != isWithinReferenceRange { synchronizePlayer() }
        if next >= totalDurationFrames { pause() }
    }

    private func synchronizePlayer() {
        seekGeneration += 1
        let generation = seekGeneration
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        guard isWithinReferenceRange, let time = referenceTime(forTimelineFrame: timelineFrame) else {
            isSeeking = false
            return
        }
        isSeeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = !finished
                if finished && self.isPlaying && self.isWithinReferenceRange {
                    self.playbackStartFrame = self.timelineFrame
                    self.playbackStartTime = ProcessInfo.processInfo.systemUptime
                    self.player.play()
                }
            }
        }
    }

    private func updateTimecodeDisplay() {
        currentTimecodeString = timelineStartTC.adding(frames: timelineFrame).description
        scrubPosition = totalDurationFrames > 0 ? Double(timelineFrame) / Double(totalDurationFrames) : 0
        onPlayheadFrameChanged?(timelineFrame)
    }

    deinit {
        playbackTimer?.invalidate()
        durationTask?.cancel()
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if isAccessingSecurityScopedURL { accessScopeURL?.stopAccessingSecurityScopedResource() }
    }
}
