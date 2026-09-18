import AVKit
import SwiftUI

struct MediaPlayerView: View {
    private let playlist: [FileEntry]

    @State private var index: Int
    @State private var player = AVPlayer()
    @State private var errorText: String?

    init(entry: FileEntry, siblings: [FileEntry]) {
        var list = siblings
        if let position = list.firstIndex(where: { $0.path == entry.path }) {
            _index = State(initialValue: position)
        } else {
            list.insert(entry, at: 0)
            _index = State(initialValue: 0)
        }
        playlist = list
    }

    private var currentEntry: FileEntry { playlist[index] }
    private var canPlayPrevious: Bool { index > 0 }
    private var canPlayNext: Bool { index + 1 < playlist.count }

    var body: some View {
        Group {
            if let errorText = errorText {
                Text(errorText)
                    .font(.body)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlayerControllerView(player: player)
            }
        }
        .background(Color.black)
        .navigationTitle(currentEntry.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { playbackBar }
        .onAppear {
            activateAudioSession()
            if player.currentItem == nil {
                loadCurrentItem(autoPlay: true)
            } else {
                player.play()
            }
        }
        .onDisappear {
            player.pause()
            deactivateAudioSession()
        }
        .onChange(of: index) { _ in
            loadCurrentItem(autoPlay: true)
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 32) {
            Button {
                index -= 1
            } label: {
                Label("上一集", systemImage: "backward.end.fill")
            }
            .disabled(!canPlayPrevious)

            Button {
                index += 1
            } label: {
                Label("下一集", systemImage: "forward.end.fill")
            }
            .disabled(!canPlayNext)
        }
        .font(.body)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func loadCurrentItem(autoPlay: Bool) {
        let entry = currentEntry
        guard FileManager.default.fileExists(atPath: entry.path) else {
            player.replaceCurrentItem(with: nil)
            errorText = "文件不存在：\(entry.name)"
            return
        }
        errorText = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: entry.path)))
        if autoPlay {
            player.play()
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            AppLog.tag("Media", "audio session activate failed: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.tag("Media", "audio session deactivate failed: \(error.localizedDescription)")
        }
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
