import SwiftUI
import AVKit

struct VideoPlayerContent: View {
    let isEmbedded: Bool
    @Environment(AppState.self) private var appState

    private var coordinator: PlaybackCoordinator? {
        appState.playbackCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video area with source TC overlay
            ZStack(alignment: .bottomLeading) {
                if let player = coordinator?.player {
                    VideoPlayerNSView(player: player)
                } else {
                    // Blank placeholder when no reference is loaded
                    Color.black
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "film")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white.opacity(0.15))
                                Text("No Reference Linked")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.25))
                                Button("Link Reference...") {
                                    appState.isShowingReferenceMatchSheet = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                }

                if let message = coordinator?.referenceStatusMessage {
                    Color.black.overlay {
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }

                // Source TC overlay
                if appState.showSourceTCOverlay && !appState.sourceTimecodesAtPlayhead.isEmpty {
                    SourceTCOverlayView(entries: appState.sourceTimecodesAtPlayhead)
                }
            }
            .clipped()

            // Compact control bar
            HStack(spacing: 6) {
                // Timecode display — shows timeline record TC
                Text(appState.currentRecordTimecode)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(appState.currentTimelineData != nil ? 0.7 : 0.25))
                    .frame(minWidth: 70, alignment: .leading)

                Spacer()

                // Transport controls
                HStack(spacing: 12) {
                    Button {
                        coordinator?.stepBackward()
                    } label: {
                        Image(systemName: "backward.frame.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .disabled(coordinator == nil)

                    Button {
                        coordinator?.togglePlayPause()
                    } label: {
                        Image(systemName: coordinator?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .disabled(coordinator == nil)

                    Button {
                        coordinator?.stepForward()
                    } label: {
                        Image(systemName: "forward.frame.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .disabled(coordinator == nil)
                }

                Spacer()

                if let id = appState.selectedSequenceID, let match = appState.referenceMatches[id] {
                    Toggle("Ignore reference timecode", isOn: Binding(
                        get: { match.ignoreReferenceTimecode },
                        set: { appState.setIgnoreReferenceTimecode($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                }

                // Source TC overlay toggle
                Button {
                    appState.showSourceTCOverlay.toggle()
                } label: {
                    Image(systemName: appState.showSourceTCOverlay ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(appState.showSourceTCOverlay ? .white : .white.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .help("Toggle source timecodes")

                // Pop-out / embed button
                if isEmbedded {
                    Button {
                        appState.popOutPlayer()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Pop out to floating window")
                } else {
                    Button {
                        appState.embedPlayer()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Embed back in main window")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .background(Color.black)
    }
}

// MARK: - Source TC Overlay

struct SourceTCOverlayView: View {
    let entries: [AppState.SourceTCEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    Text(entry.trackLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(entry.timecode)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(entry.clipName)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(6)
    }
}

// MARK: - AVPlayerView wrapper

struct VideoPlayerNSView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
