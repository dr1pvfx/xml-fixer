import XCTest
import AVFoundation
@testable import XML_Fixer

final class AppWorkflowSmokeTests: XCTestCase {

    private var fixtureURL: URL {
        Bundle(for: type(of: self)).url(forResource: "sample_sequence", withExtension: "xml")
            ?? URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/sample_sequence.xml")
    }

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RPBXMLToolkitSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testPrimaryAppWorkflowWithFixture() async throws {
        let appState = AppState()

        appState.importFiles(urls: [fixtureURL])
        waitUntil("XML import") { !appState.isProcessing }

        XCTAssertEqual(appState.documents.count, 1)
        XCTAssertEqual(appState.mediaReferences.count, 4)

        let sequence = try XCTUnwrap(appState.documents.first?.sequences.first { $0.name == "Test Timeline" })
        appState.selectedSequenceID = sequence.id
        appState.refreshTimelineData()
        XCTAssertNotNil(appState.currentTimelineData)

        try exerciseRelink(appState: appState)
        try exerciseCleanXMLExport(appState: appState)
        try exerciseSourcesXMLExport(appState: appState)
        try await exerciseReferenceMatching(appState: appState, sequence: sequence)
    }

    func testCompactTimecodeInputAndValidation() throws {
        for (input, expected) in [("000000", "00:00:00:00"), ("01000000", "01:00:00:00"),
                                  ("123456", "00:12:34:56"), ("00:59:59:00", "00:59:59:00")] {
            let formatted = TimecodeUtil.formatInput(input)
            XCTAssertEqual(Timecode.parse(formatted, timebase: 60)?.description, expected)
        }
        XCTAssertEqual(TimecodeUtil.formatInput("01000000"), "01:00:00:00")
        XCTAssertNil(Timecode.parse("00:00:00:25", timebase: 25))
        XCTAssertNil(Timecode.parse("00:60:00:00", timebase: 25))
        XCTAssertNil(Timecode.parse("24:00:00:00", timebase: 25))
        XCTAssertNil(Timecode.parse("bad:00:00:00:00", timebase: 25))
        XCTAssertNil(Timecode.parse("00:00:00:00", timebase: 25, dropFrame: true))
    }

    func testDropFrameRoundTripAndSkippedLabels() throws {
        for timebase in [30, 60] {
            for frame in [0, 1799, 1800, 17982, 107892, 215784, 2589407] {
                let tc = Timecode.fromFrames(frame, timebase: timebase, dropFrame: true)
                XCTAssertEqual(Timecode.parse(tc.description, timebase: timebase)?.totalFrames, frame)
            }
        }
        XCTAssertEqual(Timecode.parse("01:00:00;00", timebase: 30)?.totalFrames, 107892)
        XCTAssertNil(Timecode.parse("00:01:00;00", timebase: 30))
        XCTAssertEqual(Timecode.fromFrames(1800, timebase: 30, dropFrame: true).description, "00:01:00;02")
    }

    private var referenceFixtureURL: URL {
        Bundle(for: type(of: self)).url(forResource: "reference_25fps", withExtension: "mov")
            ?? URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/reference_25fps.mov")
    }

    @MainActor
    func testEmbeddedReferenceTimecodeAndRangeBoundaries() async throws {
        let embedded = await AVAssetTimecodeReader.readStartTimecode(from: referenceFixtureURL, timebase: 25)
        let tc = try XCTUnwrap(embedded)
        XCTAssertEqual(tc.description, "01:00:00:00")
        let coordinator = PlaybackCoordinator(referenceURL: referenceFixtureURL,
            timelineStartTC: try XCTUnwrap(Timecode.parse("00:59:59:00", timebase: 25)),
            referenceStartTC: tc, timebase: 25, totalDurationFrames: 100)
        try await waitForReference(coordinator)
        coordinator.seekToTimelineFrame(0)
        XCTAssertEqual(coordinator.timelineFrame, 0)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 0)?.seconds, -1)
        XCTAssertFalse(coordinator.isWithinReferenceRange)
        coordinator.seekToTimelineFrame(24)
        XCTAssertFalse(coordinator.isWithinReferenceRange)
        coordinator.stepForward()
        XCTAssertEqual(coordinator.timelineFrame, 25)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 25)?.seconds, 0)
        XCTAssertTrue(coordinator.isWithinReferenceRange)
        coordinator.seekToTimelineFrame(74)
        XCTAssertTrue(coordinator.isWithinReferenceRange)
        coordinator.stepForward()
        XCTAssertFalse(coordinator.isWithinReferenceRange)
        XCTAssertEqual(coordinator.timelineFrame, 75)
        coordinator.stepBackward()
        XCTAssertTrue(coordinator.isWithinReferenceRange)
    }

    @MainActor
    func testSequenceTCEditBatchUndoAndIgnoreModeRefreshAlignment() async throws {
        let state = AppState()
        let changedFixture = tempRoot.appendingPathComponent("sequence_25fps.xml")
        let fixtureText = try String(contentsOf: fixtureURL)
            .replacingOccurrences(of: "<timebase>24</timebase>", with: "<timebase>25</timebase>")
        try fixtureText.write(to: changedFixture, atomically: true, encoding: .utf8)
        let doc = try FCPXMLParser.parse(url: changedFixture)
        state.documents = [doc]
        let sequence = try XCTUnwrap(doc.sequences.first { $0.name == "Test Timeline" })
        state.selectedSequenceID = sequence.id
        state.refreshTimelineData()
        let referenceTC = try XCTUnwrap(Timecode.parse("01:00:00:00", timebase: 25))
        state.applyReferenceMatches([ReferenceMatch(sequenceID: sequence.id, sequenceName: sequence.name,
            parentDocumentID: doc.id, candidates: [ReferenceCandidate(url: referenceFixtureURL,
                filenameStem: "reference_25fps", fileExtension: "mov", fileSize: 1, embeddedTimecode: referenceTC)],
            selectedCandidateIndex: 0, status: .matched)])
        let coordinator = try XCTUnwrap(state.playbackCoordinator)
        try await waitForReference(coordinator)
        state.updateSequenceTimecode(sequenceID: sequence.id, newTC: "00:59:59:00", frame: 89975, displayFormat: "NDF")
        state.seekPlayhead(toFrame: 0)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 0)?.seconds, -1)
        XCTAssertFalse(coordinator.isWithinReferenceRange)
        XCTAssertEqual(state.playheadFrame, 0)
        state.seekPlayhead(toFrame: 25)
        XCTAssertTrue(coordinator.isWithinReferenceRange)
        state.updateSequenceTimecode(sequenceID: sequence.id, newTC: "01:00:00:00", frame: 90000, displayFormat: "NDF")
        XCTAssertTrue(state.playbackCoordinator === coordinator)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 25)?.seconds, 1)
        XCTAssertEqual(state.playheadFrame, 25)
        XCTAssertEqual(try doc.xmlDocument.nodes(forXPath: "//sequence[@id='\(sequence.sequenceElementID!)']/timecode/frame").first?.stringValue, "90000")
        state.undo()
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 25)?.seconds, 0)
        state.setIgnoreReferenceTimecode(true)
        state.seekPlayhead(toFrame: 0)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 0)?.seconds, 0)
        XCTAssertTrue(coordinator.isWithinReferenceRange)
        state.batchUpdateTimecodes(newTC: "01:00:01:00", frame: 90025, displayFormat: "NDF")
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 0)?.seconds, 0)
        state.setIgnoreReferenceTimecode(false)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 0)?.seconds, 1)
        state.closeVideoPlayer()
    }

    func testMissingTimecodeRequiresExplicitIgnoreAndNTSCSeeksAreRational() {
        let coordinator = PlaybackCoordinator(referenceURL: referenceFixtureURL,
            timelineStartTC: Timecode.fromFrames(0, timebase: 30), referenceStartTC: nil,
            timebase: 30, totalDurationFrames: 200, ntsc: true)
        XCTAssertNil(coordinator.referenceTime(forTimelineFrame: 30))
        coordinator.updateAlignment(timelineStartTC: Timecode.fromFrames(0, timebase: 30),
            referenceStartTC: nil, ignoreReferenceTimecode: true, timelineFrame: 30)
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 30)?.seconds ?? 0, 1.001, accuracy: 0.000001)
    }

    @MainActor
    func testReferenceUsesItsOwnFrameRateForTimecodeMatching() async throws {
        let coordinator = PlaybackCoordinator(referenceURL: referenceFixtureURL,
            timelineStartTC: Timecode.fromFrames(108000, timebase: 30),
            referenceStartTC: Timecode.fromFrames(90000, timebase: 25),
            timebase: 30, totalDurationFrames: 200, ntsc: true)
        try await waitForReference(coordinator)
        // One hour NDF at 29.97fps is 3603.6 real seconds. The 25fps MOV
        // starts at 3600 real seconds, without the sequence's NTSC factor.
        XCTAssertEqual(coordinator.referenceTime(forTimelineFrame: 0)?.seconds ?? 0, 3.6, accuracy: 0.000001)
    }

    @MainActor
    func testPlaybackAdvancesThroughLeadingAndTrailingReferenceGaps() async throws {
        let coordinator = PlaybackCoordinator(referenceURL: referenceFixtureURL,
            timelineStartTC: Timecode.fromFrames(89975, timebase: 25),
            referenceStartTC: Timecode.fromFrames(90000, timebase: 25), timebase: 25, totalDurationFrames: 100)
        try await waitForReference(coordinator)
        coordinator.seekToTimelineFrame(23)
        coordinator.togglePlayPause()
        try await Task.sleep(for: .milliseconds(220))
        coordinator.togglePlayPause()
        XCTAssertGreaterThanOrEqual(coordinator.timelineFrame, 25)
        XCTAssertTrue(coordinator.isWithinReferenceRange)
        coordinator.seekToTimelineFrame(73)
        coordinator.togglePlayPause()
        try await Task.sleep(for: .milliseconds(220))
        coordinator.togglePlayPause()
        XCTAssertGreaterThanOrEqual(coordinator.timelineFrame, 75)
        XCTAssertFalse(coordinator.isWithinReferenceRange)
    }

    @MainActor
    private func waitForReference(_ coordinator: PlaybackCoordinator) async throws {
        for _ in 0..<100 {
            if coordinator.referenceDuration != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Reference duration did not load")
    }

    private func exerciseRelink(appState: AppState) throws {
        let conformDir = tempRoot.appendingPathComponent("Conform", isDirectory: true)
        try FileManager.default.createDirectory(at: conformDir, withIntermediateDirectories: true)

        let conformFile = conformDir.appendingPathComponent("A_0012_001_h3F2A.mov")
        try Data("dummy media".utf8).write(to: conformFile)

        let media = try XCTUnwrap(appState.mediaReferences.first { $0.filename == "A_0012_001_h3F2A.mov" })
        let match = RelinkMatch(
            mediaFilename: media.filename,
            mediaID: media.id,
            candidates: [
                RelinkCandidate(
                    url: conformFile,
                    filenameStem: conformFile.deletingPathExtension().lastPathComponent,
                    fileExtension: conformFile.pathExtension,
                    fileSize: 11
                )
            ],
            selectedCandidateIndex: 0,
            status: .matched,
            userConfirmed: true
        )

        appState.applyRelink([match])

        let relinked = try XCTUnwrap(appState.mediaReferences.first { $0.filename == media.filename })
        XCTAssertEqual(relinked.pathURL, URL(fileURLWithPath: conformFile.path).absoluteString)
    }

    private func exerciseCleanXMLExport(appState: AppState) throws {
        let outputDir = tempRoot.appendingPathComponent("CleanExports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        appState.exportOptions.outputDirectory = outputDir
        appState.exportOptions.filenameSuffix = "_qa"
        appState.exportOptions.shouldRepairReelMetadata = false
        appState.exportAll()
        waitUntil("clean XML export") { !appState.isProcessing }

        let exported = outputDir.appendingPathComponent("sample_sequence_qa.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        let contents = try String(contentsOf: exported)
        XCTAssertTrue(contents.contains("<xmeml"))
    }

    private func exerciseSourcesXMLExport(appState: AppState) throws {
        let outputDir = tempRoot.appendingPathComponent("SourcesExports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        appState.sourcesExportOptions.outputDirectory = outputDir
        appState.sourcesExportOptions.outputFilename = "Sources_QA.xml"
        appState.exportSourcesSequence()
        waitUntil("Sources XML export") { !appState.isProcessing }

        let exported = outputDir.appendingPathComponent("Sources_QA.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        let contents = try String(contentsOf: exported)
        XCTAssertTrue(contents.contains("<!DOCTYPE xmeml>"))
        XCTAssertTrue(contents.contains("<sequence"))
    }

    private func exerciseReferenceMatching(appState: AppState, sequence: SequenceInfo) async throws {
        let referenceDir = tempRoot.appendingPathComponent("References", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)

        let referenceFile = referenceDir.appendingPathComponent("Test Timeline.mov")
        try Data("dummy reference".utf8).write(to: referenceFile)

        let scanned = await FileScanner.scan(directory: referenceDir, extensionFilter: "mov")
        var matches = ReferenceMatchEngine.match(
            sequences: [(id: sequence.id, name: sequence.name, parentDocumentID: sequence.parentDocumentID)],
            against: scanned,
            strictMode: true,
            minChars: 6
        )
        for index in matches.indices {
            matches[index].accessScopeURL = referenceDir
        }

        XCTAssertEqual(matches.first?.selectedURL?.lastPathComponent, "Test Timeline.mov")
        appState.applyReferenceMatches(matches)

        XCTAssertNotNil(appState.referenceMatches[sequence.id])
        XCTAssertNotNil(appState.playbackCoordinator)
        appState.closeVideoPlayer()
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
