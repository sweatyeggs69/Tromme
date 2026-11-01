import CarPlay
import UIKit

@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Voice Search

    func makeSearchList() -> CPListTemplate {
        let item = CPListItem(text: "Say a Song or Artist", detailText: nil, image: UIImage(systemName: "mic.fill"))
        item.handler = { [weak self] _, completion in
            self?.startVoiceSearch()
            completion()
        }
        return CPListTemplate(title: "Search", sections: [CPListSection(items: [item])])
    }

    func startVoiceSearch() {
        let image = UIImage(systemName: "mic.fill") ?? UIImage()
        let states = [
            CPVoiceControlState(identifier: "listening", titleVariants: ["Listening"], image: image, repeats: true),
            CPVoiceControlState(identifier: "searching", titleVariants: ["Searching"], image: image, repeats: true),
            CPVoiceControlState(identifier: "failed", titleVariants: ["Nothing Found"], image: image, repeats: false),
        ]
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        interfaceController?.pushTemplate(template, animated: true) { _, _ in
            template.activateVoiceControlState(withIdentifier: "listening")
        }

        let wasPlaying = player.isPlaying
        if wasPlaying { player.togglePlayPause() }

        Task {
            do {
                let spoken = try await CarPlayVoiceRecognizer().listen()
                template.activateVoiceControlState(withIdentifier: "searching")
                let results = try await MusicItemResolver.search(spoken, limit: 5)
                let match = results.first { $0.title.localizedCaseInsensitiveCompare(spoken) == .orderedSame } ?? results.first
                guard let match else { throw MusicItemResolverError.nothingFound }
                let tracks = try await MusicItemResolver.tracks(for: match)
                guard interfaceController?.topTemplate === template else { return }
                if match.kind == .artist, !player.isShuffled { player.toggleShuffle() }
                player.play(tracks: tracks, startingAt: 0)
                interfaceController?.popTemplate(animated: false) { [weak self] _, _ in
                    self?.pushNowPlaying()
                }
            } catch {
                template.activateVoiceControlState(withIdentifier: "failed")
                if wasPlaying, !player.isPlaying { player.togglePlayPause() }
                try? await Task.sleep(for: .seconds(1.5))
                if interfaceController?.topTemplate === template {
                    interfaceController?.popTemplate(animated: true, completion: nil)
                }
            }
        }
    }
}
