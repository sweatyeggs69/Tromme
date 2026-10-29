import AVFoundation

/// The next song, loaded and silent ahead of an Auto Mix so it can start the moment the mix does.
struct PreparedMixIncoming {
    let ratingKey: String
    let url: URL
    let player: AVQueuePlayer
    let item: AVPlayerItem
}
