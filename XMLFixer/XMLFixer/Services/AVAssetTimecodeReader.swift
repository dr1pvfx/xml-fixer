import AVFoundation

enum AVAssetTimecodeReader {
    /// Read the embedded starting timecode from a QuickTime/MP4 file.
    static func readStartTimecode(from url: URL, timebase: Int) async -> Timecode? {
        let asset = AVAsset(url: url)

        // Try timecode track first
        if let tc = await readFromTimecodeTrack(asset: asset, timebase: timebase) {
            return tc
        }

        // Fallback: check metadata
        if let tc = await readFromMetadata(asset: asset, timebase: timebase) {
            return tc
        }

        return nil
    }

    private static func readFromTimecodeTrack(asset: AVAsset, timebase: Int) async -> Timecode? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .timecode)
            guard let track = tracks.first else { return nil }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { return nil }
            defer { reader.cancelReading() }

            // AVFoundation may emit empty edit-boundary buffers before the first
            // timecode sample. They carry no format/data and must be skipped.
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0,
                      let format = CMSampleBufferGetFormatDescription(sample),
                      let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let subtype = CMFormatDescriptionGetMediaSubType(format)
                let byteCount: Int
                switch subtype {
                case kCMTimeCodeFormatType_TimeCode32: byteCount = 4
                case kCMTimeCodeFormatType_TimeCode64: byteCount = 8
                default: continue
                }
                guard CMBlockBufferGetDataLength(block) >= byteCount else { continue }
                var bytes = [UInt8](repeating: 0, count: byteCount)
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                let bits = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let signed = byteCount == 4 ? Int64(Int32(bitPattern: UInt32(bits))) : Int64(bitPattern: bits)
                guard let frameNumber = Int(exactly: signed), frameNumber >= 0 else { continue }
                let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
                let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format)
                return Timecode.fromFrames(frameNumber, timebase: quanta > 0 ? quanta : timebase,
                    dropFrame: (flags & UInt32(kCMTimeCodeFlag_DropFrame)) != 0)
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func readFromMetadata(asset: AVAsset, timebase: Int) async -> Timecode? {
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if let key = item.commonKey?.rawValue, key.lowercased().contains("timecode") {
                    if let stringValue = try await item.load(.stringValue) {
                        return Timecode.parse(stringValue, timebase: timebase)
                    }
                }
            }
        } catch {
            // Metadata read failed
        }
        return nil
    }
}
