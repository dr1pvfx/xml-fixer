import Foundation

/// Frame-accurate timecode value type for FCP XML timecodes.
struct Timecode: Equatable, CustomStringConvertible {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    let timebase: Int
    let isDropFrame: Bool

    var totalFrames: Int {
        let nominal = (hours * 3600 + minutes * 60 + seconds) * timebase + frames
        guard isDropFrame, timebase == 30 || timebase == 60 else { return nominal }
        let totalMinutes = hours * 60 + minutes
        return nominal - (timebase / 15) * (totalMinutes - totalMinutes / 10)
    }

    var description: String {
        let sep = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// Parse "HH:MM:SS:FF" or "HH:MM:SS;FF" string
    static func parse(_ string: String, timebase: Int, dropFrame: Bool = false) -> Timecode? {
        guard timebase > 0 else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned: String
        if !trimmed.isEmpty && trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard trimmed.count <= 8 else { return nil }
            let digits = String(repeating: "0", count: 8 - trimmed.count) + trimmed
            cleaned = stride(from: 0, to: 8, by: 2).map { offset in
                String(digits.dropFirst(offset).prefix(2))
            }.joined(separator: ":")
        } else {
            cleaned = trimmed.replacingOccurrences(of: ";", with: ":")
        }
        let fields = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        if fields.count < 4 && fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) {
            return parse(fields.joined(), timebase: timebase, dropFrame: dropFrame)
        }
        guard fields.count == 4,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let parts = fields.compactMap { Int($0) }
        guard parts.count == 4, (0...23).contains(parts[0]),
              (0...59).contains(parts[1]), (0...59).contains(parts[2]),
              (0..<timebase).contains(parts[3]) else { return nil }
        let isDF = dropFrame || trimmed.contains(";")
        if isDF {
            guard timebase == 30 || timebase == 60 else { return nil }
            // Drop-frame labels omit the first 2 (or 4) numbers each minute,
            // except every tenth minute.
            if parts[1] % 10 != 0 && parts[2] == 0 && parts[3] < timebase / 15 { return nil }
        }
        return Timecode(hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3], timebase: timebase, isDropFrame: isDF)
    }

    /// Create from total frame count
    static func fromFrames(_ totalFrames: Int, timebase: Int, dropFrame: Bool = false) -> Timecode {
        guard timebase > 0 else {
            return Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, timebase: timebase, isDropFrame: dropFrame)
        }
        var labelledFrames = max(0, totalFrames)
        if dropFrame && (timebase == 30 || timebase == 60) {
            let drop = timebase / 15
            let framesPerTenMinutes = timebase * 600 - drop * 9
            let tens = labelledFrames / framesPerTenMinutes
            let remainder = labelledFrames % framesPerTenMinutes
            labelledFrames += drop * 9 * tens
            if remainder >= drop {
                labelledFrames += drop * ((remainder - drop) / (timebase * 60 - drop))
            }
        }
        let f = labelledFrames % timebase
        let totalSeconds = labelledFrames / timebase
        let s = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let m = totalMinutes % 60
        let h = totalMinutes / 60
        return Timecode(hours: h, minutes: m, seconds: s, frames: f, timebase: timebase, isDropFrame: dropFrame)
    }

    /// Add frame offset
    func adding(frames offset: Int) -> Timecode {
        Timecode.fromFrames(totalFrames + offset, timebase: timebase, dropFrame: isDropFrame)
    }

    /// Frame difference (self - other), can be negative
    func framesDifference(from other: Timecode) -> Int {
        totalFrames - other.totalFrames
    }
}
