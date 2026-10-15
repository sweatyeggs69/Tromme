import AVFoundation
import MediaPlayer
import Network
import Observation

// Press-and-hold skip buttons.
extension AudioPlayerService {
    // MARK: - Held Seek (press-and-hold skip buttons)

    /// Starts a repeating ±10s scrub while a remote skip button is held
    /// (CarPlay / lock screen send begin- and endSeeking events for this).
    /// Only the timeline is advanced per step; the actual player seek is
    /// committed once on release so a streamed transcode session restarts
    /// once instead of once per step.
    func beginHeldSeek(forward: Bool) {
        guard hasTrack else { return }
        heldSeekTask?.cancel()
        isSeeking = true
        heldSeekTargetTime = currentTime
        logPlayback("held_seek_begin", "forward=\(forward)")
        let step: TimeInterval = forward ? 10 : -10
        heldSeekTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let upperBound = self.duration > 0 ? self.duration : .greatestFiniteMagnitude
                self.heldSeekTargetTime = min(max(self.heldSeekTargetTime + step, 0), upperBound)
                self.currentTime = self.heldSeekTargetTime
                self.updateNowPlayingInfo()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func endHeldSeek() {
        guard heldSeekTask != nil else { return }
        heldSeekTask?.cancel()
        heldSeekTask = nil
        isSeeking = false
        logPlayback("held_seek_end", "target=\(heldSeekTargetTime)")
        seek(to: heldSeekTargetTime)
    }

    func addToQueue(_ track: PlexMetadata) {
        let insertIndex = currentIndex + 1
        queue.insert(track, at: min(insertIndex, queue.count))
        originalQueue.append(track)
        savePlaybackState()
        syncDynamicQueueDownloads()
    }

    func addToEndOfQueue(_ track: PlexMetadata) {
        queue.append(track)
        originalQueue.append(track)
        savePlaybackState()
        syncDynamicQueueDownloads()
    }

    func removeFromQueue(at index: Int) {
        let queueIndex = currentIndex + 1 + index
        guard queueIndex < queue.count else { return }
        let track = queue.remove(at: queueIndex)
        if let origIndex = originalQueue.firstIndex(where: { $0.ratingKey == track.ratingKey }) {
            originalQueue.remove(at: origIndex)
        }
        savePlaybackState()
    }

    func playFromQueue(at index: Int) {
        let queueIndex = currentIndex + 1 + index
        guard queueIndex < queue.count else { return }
        let track = queue.remove(at: queueIndex)
        queue.insert(track, at: currentIndex + 1)
        currentIndex += 1
        loadAndPlay(queue[currentIndex])
    }

    /// Jump to an upcoming track by offset without reordering the queue.
    func skipToUpcoming(at offset: Int) {
        let queueIndex = currentIndex + 1 + offset
        guard queue.indices.contains(queueIndex) else { return }
        currentIndex = queueIndex
        loadAndPlay(queue[currentIndex])
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        var upcoming = Array(queue[(currentIndex + 1)...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange((currentIndex + 1)..., with: upcoming)
    }

    func toggleShuffle() {
        // If queue is empty but we have a current track (e.g. restored state), seed the queue
        if queue.isEmpty, let track = currentTrack {
            queue = [track]
            originalQueue = [track]
            currentIndex = 0
        }
        guard !queue.isEmpty else { return }
        isShuffled.toggle()
        if isShuffled {
            let current = queue[currentIndex]
            var remaining = queue
            remaining.remove(at: currentIndex)
            remaining.shuffle()
            remaining.insert(current, at: 0)
            queue = remaining
            currentIndex = 0
        } else {
            if let current = currentTrack,
               let idx = originalQueue.firstIndex(where: { $0.ratingKey == current.ratingKey }) {
                queue = originalQueue
                currentIndex = idx
            }
        }
        // The queue didSet ran before currentIndex was updated above.
        revalidatePreloadedNext()
        savePlaybackState()
        updateShuffleRepeatState()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .song
        case .song: repeatMode = .once
        case .once: repeatMode = .off
        }
        savePlaybackState()
        updateShuffleRepeatState()
    }

    func shuffleUpcomingQueue() {
        guard currentIndex + 1 < queue.count else { return }
        var upcoming = Array(queue[(currentIndex + 1)...])
        upcoming.shuffle()
        queue.replaceSubrange((currentIndex + 1)..., with: upcoming)
    }
}
