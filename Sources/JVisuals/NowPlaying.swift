import AppKit

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Seconds.
    let duration: Double
    var artwork: URL?
}

/// Follows what Spotify is playing. Spotify posts a distributed notification on every play/pause/track change,
/// which needs no permission; one AppleScript query (asks for Automation permission once) fills in the state at
/// launch and the artwork URL, which the notification doesn't carry.
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    /// Playback position in seconds as of `positionDate`.
    @Published private(set) var position: Double = 0
    private(set) var positionDate = Date()

    private static let bundleID = "com.spotify.client"
    private let scriptQueue = DispatchQueue(label: "JVisuals.nowplaying")
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            self?.apply(note.userInfo ?? [:])
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Self.bundleID { self?.clear() }
        })
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            query()
        }
    }

    /// Current position, advanced by the time since the last update while playing.
    func elapsed(at date: Date) -> Double {
        let moved = isPlaying ? date.timeIntervalSince(positionDate) : 0
        return min(position + moved, track?.duration ?? 0)
    }

    deinit {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func apply(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let id = info["Track ID"] as? String else {
            clear()
            return
        }
        let durationMS = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let isNew = id != track?.id
        track = Track(id: id,
                      title: info["Name"] as? String ?? "",
                      artist: info["Artist"] as? String ?? "",
                      album: info["Album"] as? String ?? "",
                      duration: durationMS / 1000,
                      artwork: isNew ? nil : track?.artwork)
        isPlaying = state == "Playing"
        position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        positionDate = Date()
        if isNew { query() }
    }

    private func clear() {
        track = nil
        isPlaying = false
    }

    /// Asks Spotify directly for the full state, including artwork. Runs off the main thread.
    private func query() {
        let source = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set t to current track
                return {player state as string, id of t, name of t, artist of t, album of t, ¬
                    duration of t, player position, artwork url of t}
            end tell
        end if
        return "stopped"
        """
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
                  result.numberOfItems == 8 else { return }
            func string(_ i: Int) -> String { result.atIndex(i)?.stringValue ?? "" }
            let durationMS = Double(string(6)) ?? 0
            let position = Double(string(7)) ?? 0
            let playing = string(1) == "playing"
            let track = Track(id: string(2), title: string(3), artist: string(4), album: string(5),
                              duration: durationMS / 1000, artwork: URL(string: string(8)))
            DispatchQueue.main.async {
                guard let self else { return }
                // A notification may have arrived meanwhile; only take over if it's still the same track.
                if self.track == nil || self.track?.id == track.id {
                    self.track = track
                    self.isPlaying = playing
                    self.position = position
                    self.positionDate = Date()
                }
            }
        }
    }
}
