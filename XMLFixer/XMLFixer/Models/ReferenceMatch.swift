import Foundation

enum ReferenceMatchStatus {
    case unmatched
    case matched
    case multipleFound
}

struct ReferenceCandidate: Identifiable {
    let id: UUID
    let url: URL
    let filenameStem: String
    let fileExtension: String
    let fileSize: Int64
    var embeddedTimecode: Timecode?

    init(id: UUID = UUID(), url: URL, filenameStem: String, fileExtension: String, fileSize: Int64, embeddedTimecode: Timecode? = nil) {
        self.id = id
        self.url = url
        self.filenameStem = filenameStem
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.embeddedTimecode = embeddedTimecode
    }

    var displaySize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var displayFilename: String {
        filenameStem + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
    }
}

struct ReferenceMatch: Identifiable {
    let id: UUID
    let sequenceID: UUID
    let sequenceName: String
    let parentDocumentID: UUID
    var accessScopeURL: URL?
    var candidates: [ReferenceCandidate]
    var selectedCandidateIndex: Int?
    var status: ReferenceMatchStatus
    var userConfirmed: Bool
    var ignoreReferenceTimecode: Bool = false

    init(id: UUID = UUID(), sequenceID: UUID, sequenceName: String, parentDocumentID: UUID, accessScopeURL: URL? = nil, candidates: [ReferenceCandidate] = [], selectedCandidateIndex: Int? = nil, status: ReferenceMatchStatus = .unmatched, userConfirmed: Bool = false) {
        self.id = id
        self.sequenceID = sequenceID
        self.sequenceName = sequenceName
        self.parentDocumentID = parentDocumentID
        self.accessScopeURL = accessScopeURL
        self.candidates = candidates
        self.selectedCandidateIndex = selectedCandidateIndex
        self.status = status
        self.userConfirmed = userConfirmed
    }

    var selectedURL: URL? {
        guard let idx = selectedCandidateIndex, idx < candidates.count else { return nil }
        return candidates[idx].url
    }

    var selectedTimecode: Timecode? {
        guard let idx = selectedCandidateIndex, idx < candidates.count else { return nil }
        return candidates[idx].embeddedTimecode
    }
}
