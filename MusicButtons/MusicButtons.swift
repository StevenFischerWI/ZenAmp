import SwiftUI
import AppKit
import CoreAudio
import ImageIO
import MusicKit
import Combine

// MARK: - Audio Output Manager

class AudioOutputManager {
    struct OutputDevice {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }

    static func listOutputDevices() -> [OutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        let defaultID = getDefaultOutputDeviceID()

        return deviceIDs.compactMap { id -> OutputDevice? in
            guard hasOutputStreams(deviceID: id) else { return nil }
            guard let name = getDeviceName(deviceID: id) else { return nil }
            return OutputDevice(id: id, name: name, isDefault: id == defaultID)
        }
    }

    static func setDefaultOutput(deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
    }

    private static func getDefaultOutputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceID)
        return deviceID
    }

    private static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else { return false }
        return dataSize > 0
    }

    private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a +1 retained CFString; take ownership so it's released.
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

// MARK: - UI Scale

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Zoom factor every hardcoded dimension in the player is multiplied by.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

// MARK: - AppKit Button (works with isMovableByWindowBackground)

struct AppKitButton: NSViewRepresentable {
    let icon: String
    let size: CGFloat
    let color: NSColor
    let action: () -> Void

    private static var symbolCache: [String: NSImage] = [:]

    private static func cachedSymbol(name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = symbolCache[key] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return nil }
        symbolCache[key] = image
        return image
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = AppKitButton.cachedSymbol(name: icon, size: size)
        button.contentTintColor = color
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.currentIcon = icon
        context.coordinator.currentSize = size
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        if context.coordinator.currentIcon != icon || context.coordinator.currentSize != size {
            button.image = AppKitButton.cachedSymbol(name: icon, size: size)
            context.coordinator.currentIcon = icon
            context.coordinator.currentSize = size
        }
        if button.contentTintColor != color {
            button.contentTintColor = color
        }
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    class Coordinator: NSObject {
        var action: () -> Void
        var currentIcon: String = ""
        var currentSize: CGFloat = 0
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

struct AudioOutputMenuButton: NSViewRepresentable {
    let size: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = symbol()
        context.coordinator.currentSize = size
        button.contentTintColor = color
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        if context.coordinator.currentSize != size {
            button.image = symbol()
            context.coordinator.currentSize = size
        }
        button.contentTintColor = color
    }

    private func symbol() -> NSImage? {
        NSImage(systemSymbolName: "headphones", accessibilityDescription: "Audio Output")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        var currentSize: CGFloat = 0
        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            let devices = AudioOutputManager.listOutputDevices()
            for device in devices {
                let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(device.id)
                item.state = device.isDefault ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func selectDevice(_ sender: NSMenuItem) {
            AudioOutputManager.setDefaultOutput(deviceID: AudioDeviceID(sender.tag))
        }
    }
}

// MARK: - AppleScript Music Controller

class MusicController {

    private static let scriptTimeout: TimeInterval = 30

    static func runAppleScript(_ script: String, timeout: TimeInterval = scriptTimeout, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                let process = Process()
                let pipe = Pipe()
                let errorPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = pipe
                process.standardError = errorPipe

                do {
                    let outHandle = pipe.fileHandleForReading
                    let errHandle = errorPipe.fileHandleForReading

                    try process.run()

                    // If Music is blocked (modal dialog, sync) the Apple Event can sit
                    // for minutes — kill the script so callers always get a completion.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { process.terminate() }
                    }

                    let outputData = outHandle.readDataToEndOfFile()
                    let errorData = errHandle.readDataToEndOfFile()

                    process.waitUntilExit()

                    try? outHandle.close()
                    try? errHandle.close()

                    let output = String(data: outputData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    DispatchQueue.main.async {
                        if process.terminationStatus == 0 {
                            completion(true, output)
                        } else {
                            completion(false, errorOutput.isEmpty ? "Unknown error" : errorOutput)
                        }
                    }
                } catch {
                    try? pipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForReading.close()
                    DispatchQueue.main.async {
                        completion(false, error.localizedDescription)
                    }
                }
            }
        }
    }
    
    struct TrackInfo {
        let name: String
        let artist: String
        let playlist: String
        let isPlaying: Bool
        let position: Double
        let duration: Double
    }

    /// Track, play state and player position in a single script, so one poll is one process.
    static func getCurrentTrackInfo(completion: @escaping (TrackInfo?) -> Void) {
        let pidClause: String
        if let pid = currentPlaylistPersistentID {
            pidClause = """
                    if playlistName is "" then
                        try
                            set playlistName to name of (first playlist whose persistent ID is "\(pid)")
                        end try
                    end if
            """
        } else {
            pidClause = ""
        }
        let script = """
        if application "Music" is not running then
            return "NOTHING_PLAYING"
        end if
        tell application "Music"
            if player state is playing or player state is paused then
                set trackName to name of current track
                set trackArtist to artist of current track
                set isPlaying to (player state is playing)
                set playlistName to ""
                try
                    set playlistName to name of current playlist
                end try
                if playlistName is "" then
                    try
                        set currentSource to container of current track
                        if class of currentSource is user playlist then
                            set playlistName to name of currentSource
                        end if
                    end try
                end if
        \(pidClause)
                set pos to 0
                set dur to 0
                try
                    set pos to player position
                    set dur to duration of current track
                end try
                return trackName & " | " & trackArtist & " | " & playlistName & " | " & isPlaying & " | " & (pos as text) & " | " & (dur as text)
            else
                return "NOTHING_PLAYING"
            end if
        end tell
        """
        runAppleScript(script) { success, result in
            let parts = result.components(separatedBy: " | ")
            if success && result != "NOTHING_PLAYING" && parts.count >= 6 {
                let n = parts.count
                completion(TrackInfo(
                    name: parts[0],
                    artist: parts[1],
                    playlist: parts[2],
                    isPlaying: parts[n - 3] == "true",
                    position: Double(parts[n - 2]) ?? 0,
                    duration: Double(parts[n - 1]) ?? 0
                ))
            } else {
                completion(nil)
            }
        }
    }

    static func fetchArtwork(completion: @escaping (NSImage?) -> Void) {
        let script = """
        tell application "Music"
            if player state is playing or player state is paused then
                set t to current track
                if (count of artworks of t) > 0 then
                    set artData to data of artwork 1 of t
                    set tmpPath to "/tmp/zenamp_art.jpg"
                    set fRef to open for access POSIX file tmpPath with write permission
                    set eof fRef to 0
                    write artData to fRef
                    close access fRef
                    return tmpPath
                end if
            end if
            return "NONE"
        end tell
        """
        runAppleScript(script) { success, result in
            if success && result != "NONE" {
                // Decode straight to a thumbnail: the art is shown at 62pt (x2 zoom, x2 retina),
                // so holding the full-size bitmap just wastes memory and slows every redraw.
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256
                ]
                if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: result) as CFURL, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    completion(NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
                } else {
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
    }

    static func playPlaylist(_ playlistName: String, completion: @escaping (Bool, String) -> Void) {
        let escapedName = playlistName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            try
                play playlist "\(escapedName)"
                return "OK"
            on error
                return "NOT_FOUND"
            end try
        end tell
        """
        runAppleScript(script) { success, result in
            if success && result == "OK" {
                completion(true, "Playing: \(playlistName)")
            } else {
                completion(false, "Playlist not found")
            }
        }
    }

    static func playPause(completion: (() -> Void)? = nil) {
        let script = "tell application \"Music\" to playpause"
        runAppleScript(script) { _, _ in completion?() }
    }

    static func pause() {
        runAppleScript("tell application \"Music\" to if it is running then pause") { _, _ in }
    }

    static func nextTrack(completion: (() -> Void)? = nil) {
        let script = "tell application \"Music\" to next track"
        runAppleScript(script) { _, _ in completion?() }
    }

    static func previousTrack(completion: (() -> Void)? = nil) {
        let script = "tell application \"Music\" to previous track"
        runAppleScript(script) { _, _ in completion?() }
    }
    
    static func fetchPlaylists(completion: @escaping ([String]) -> Void) {
        let script = """
        tell application "Music"
            set playlistNames to {}
            repeat with p in playlists
                set end of playlistNames to name of p
            end repeat
            set AppleScript's text item delimiters to "|||"
            return playlistNames as text
        end tell
        """
        runAppleScript(script) { success, result in
            if success && !result.isEmpty {
                let names = result.components(separatedBy: "|||")
                completion(names)
            } else {
                completion([])
            }
        }
    }

    /// Persistent ID of the playlist the track list was last fetched from, so a click
    /// in the list plays from that same playlist.
    static var currentPlaylistPersistentID: String?

    /// True while `jumpToTrack` is skipping through a playlist; each skip posts a
    /// player-info notification that shouldn't trigger a refresh.
    static var isJumping = false

    static func fetchCurrentPlaylistTracks(completion: @escaping ([(name: String, artist: String, duration: String, isPlaying: Bool, dbID: String)]) -> Void) {
        // Source, in order of preference: the playlist Music is playing from, the one
        // we last showed, then the current track's container. Music's `current playlist`
        // also works for sources (catalog playlists, albums) whose container doesn't.
        let lastPlaylistClause: String
        if let pid = currentPlaylistPersistentID {
            lastPlaylistClause = """
                if src is missing value then
                    try
                        set src to first playlist whose persistent ID is "\(pid)"
                    end try
                end if
            """
        } else {
            lastPlaylistClause = ""
        }
        let script = """
        if application "Music" is not running then
            return ""
        end if
        tell application "Music"
            set currentName to ""
            set currentArtist to ""
            set src to missing value
            if player state is playing or player state is paused then
                try
                    set currentName to name of current track
                    set currentArtist to artist of current track
                end try
                try
                    set src to current playlist
                end try
            end if
            \(lastPlaylistClause)
            if src is missing value then
                try
                    set src to container of current track
                end try
            end if
            if src is missing value then return ""
            set srcID to ""
            try
                set srcID to "playlist:" & (persistent ID of src)
            end try
            try
                set allNames to name of tracks of src
                set allArtists to artist of tracks of src
                set allDurs to duration of tracks of src
                set allIDs to database ID of tracks of src
                set maxTracks to count of allNames
                if maxTracks > 200 then set maxTracks to 200
                set output to {srcID}
                repeat with i from 1 to maxTracks
                    set tName to item i of allNames
                    set tArtist to item i of allArtists
                    set tDur to item i of allDurs
                    set tID to item i of allIDs
                    set mins to (tDur div 60) as integer
                    set secs to (tDur mod 60) as integer
                    if secs < 10 then
                        set durStr to (mins as text) & ":0" & (secs as text)
                    else
                        set durStr to (mins as text) & ":" & (secs as text)
                    end if
                    set isNowPlaying to "0"
                    if tName is currentName and tArtist is currentArtist then
                        set isNowPlaying to "1"
                    end if
                    set end of output to tName & ":::" & tArtist & ":::" & durStr & ":::" & isNowPlaying & ":::" & (tID as text)
                end repeat
                set AppleScript's text item delimiters to "|||"
                return output as text
            end try
            return ""
        end tell
        """
        runAppleScript(script) { success, result in
            if success && !result.isEmpty {
                var lines = result.components(separatedBy: "|||")
                // First element is the source ID
                if let first = lines.first {
                    lines.removeFirst()
                    let pid = first.dropFirst("playlist:".count)
                    if first.hasPrefix("playlist:") && !pid.isEmpty {
                        currentPlaylistPersistentID = String(pid)
                    }
                }
                let tracks = lines.compactMap { line -> (name: String, artist: String, duration: String, isPlaying: Bool, dbID: String)? in
                    let parts = line.components(separatedBy: ":::")
                    guard parts.count >= 5 else { return nil }
                    return (name: parts[0], artist: parts[1], duration: parts[2], isPlaying: parts[3] == "1", dbID: parts[4])
                }
                completion(tracks)
            } else {
                completion([])
            }
        }
    }

    /// Starts playback at a track and carries on through the rest of the playlist.
    ///
    /// Music's `play <track>` plays just that one track and then stops, even when the
    /// track is referenced through its playlist. So instead: play the playlist (or stay
    /// in it, if it's already playing in order) and step through it with next/previous
    /// until the clicked track is current, muted so the skips aren't heard. Each step
    /// waits for Music to actually change track — fired back-to-back, skips get dropped.
    static func jumpToTrack(dbID: String, index: Int, playlistPersistentID pid: String, completion: @escaping (Bool) -> Void) {
        // Both values are interpolated into the script.
        guard Int(dbID) != nil, pid.allSatisfy(\.isHexDigit) else {
            completion(false)
            return
        }
        let script = """
        on currentID()
            tell application "Music"
                try
                    return database ID of current track
                on error
                    return -1
                end try
            end tell
        end currentID

        on stepFrom(previousID, direction)
            tell application "Music"
                if direction is 1 then
                    next track
                else
                    previous track
                end if
            end tell
            repeat 50 times
                set nowID to my currentID()
                if nowID is not previousID and nowID is not -1 then return nowID
                delay 0.02
            end repeat
            return previousID
        end stepFrom

        set targetID to \(dbID)
        set targetIndex to \(index)
        tell application "Music"
            set pl to first playlist whose persistent ID is "\(pid)"
            set oldVolume to sound volume
            set stayInPlace to false
            try
                set stayInPlace to (player state is not stopped) and (persistent ID of current playlist is "\(pid)") and not shuffle enabled
            end try
        end tell
        set found to false
        try
            tell application "Music"
                set sound volume to 0
                if not stayInPlace then play pl
            end tell
            set curID to -1
            repeat 50 times
                set curID to my currentID()
                if curID is not -1 then exit repeat
                delay 0.02
            end repeat
            set direction to 1
            if stayInPlace then
                tell application "Music"
                    if targetIndex < (index of current track) then
                        set direction to -1
                        -- so 'previous track' moves back rather than restarting this one
                        set player position to 0
                    end if
                end tell
            end if
            set steps to 0
            repeat while curID is not targetID and steps < 250
                set nextID to my stepFrom(curID, direction)
                if nextID is curID then exit repeat
                set curID to nextID
                set steps to steps + 1
            end repeat
            set found to (curID is targetID)
            tell application "Music"
                if found then
                    set player position to 0
                    play
                else
                    -- Couldn't reach it by stepping; at least play the track itself.
                    play (first track of pl whose database ID is targetID)
                end if
            end tell
        end try
        tell application "Music" to set sound volume to oldVolume
        if found then return "ok"
        return "fallback"
        """
        isJumping = true
        // 250 steps at ~0.3s each, plus headroom; killing it mid-way would leave Music muted.
        runAppleScript(script, timeout: 120) { success, _ in
            isJumping = false
            completion(success)
        }
    }

    static func toggleShuffle(completion: @escaping (Bool) -> Void) {
        let script = """
        tell application "Music"
            if shuffle enabled then
                set shuffle enabled to false
            else
                set shuffle enabled to true
            end if
            delay 0.2
            return shuffle enabled
        end tell
        """
        runAppleScript(script) { success, result in
            completion(result == "true")
        }
    }

    static func getVolume(completion: @escaping (Double) -> Void) {
        let script = """
        tell application "Music"
            return sound volume
        end tell
        """
        runAppleScript(script) { success, result in
            completion(Double(result) ?? 50)
        }
    }

    private static var volumeSendInFlight = false
    private static var pendingVolume: Int?

    /// Coalesces slider drags: at most one script in flight, and the latest value always wins.
    /// Call on the main thread.
    static func setVolume(_ volume: Double) {
        let v = Int(max(0, min(100, volume)))
        if volumeSendInFlight {
            pendingVolume = v
            return
        }
        volumeSendInFlight = true
        let script = "tell application \"Music\" to set sound volume to \(v)"
        runAppleScript(script) { _, _ in
            volumeSendInFlight = false
            if let next = pendingVolume {
                pendingVolume = nil
                setVolume(Double(next))
            }
        }
    }

    static func getShuffleState(completion: @escaping (Bool) -> Void) {
        let script = """
        tell application "Music"
            return shuffle enabled
        end tell
        """
        runAppleScript(script) { success, result in
            completion(result == "true")
        }
    }

    static func favoriteCurrentTrack(completion: @escaping (Bool, String) -> Void) {
        let script = """
        if application "Music" is not running then
            return "NO_TRACK"
        end if
        tell application "Music"
            if player state is playing or player state is paused then
                set favorited of current track to true
                set trackName to name of current track
                return trackName
            else
                return "NO_TRACK"
            end if
        end tell
        """
        runAppleScript(script) { success, result in
            if success && result != "NO_TRACK" {
                completion(true, "Favorited: " + result)
            } else if result == "NO_TRACK" {
                completion(false, "No track is currently playing")
            } else {
                completion(false, result)
            }
        }
    }
    
    static func addCurrentTrackToPlaylist(_ playlistName: String, completion: @escaping (Bool, String) -> Void) {
        let escapedName = playlistName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        if application "Music" is not running then
            return "NO_TRACK"
        end if
        tell application "Music"
            if player state is playing or player state is paused then
                set theTrack to current track
                set trackName to name of theTrack
                set trackArtist to artist of theTrack
                set trackDuration to duration of theTrack
                try
                    set thePlaylist to user playlist "\(escapedName)"
                    -- Check for duplicates
                    set isDuplicate to false
                    repeat with t in tracks of thePlaylist
                        if name of t is trackName and artist of t is trackArtist and duration of t is trackDuration then
                            set isDuplicate to true
                            exit repeat
                        end if
                    end repeat
                    if isDuplicate then
                        return "DUPLICATE"
                    end if
                    -- Add to playlist and favorite
                    duplicate theTrack to thePlaylist
                    set favorited of theTrack to true
                    return trackName
                on error
                    return "PLAYLIST_NOT_FOUND"
                end try
            else
                return "NO_TRACK"
            end if
        end tell
        """
        runAppleScript(script) { success, result in
            if success && result == "DUPLICATE" {
                completion(false, "Already in \(playlistName)")
            } else if success && result != "NO_TRACK" && result != "PLAYLIST_NOT_FOUND" {
                completion(true, "Added to \(playlistName): " + result)
            } else if result == "NO_TRACK" {
                completion(false, "No track is currently playing")
            } else if result == "PLAYLIST_NOT_FOUND" {
                completion(false, "Playlist \"\(playlistName)\" not found")
            } else {
                completion(false, result)
            }
        }
    }
}

// MARK: - Status Banner

enum BannerType {
    case success, error, info
    
    var color: Color {
        switch self {
        case .success: return Color.green
        case .error: return Color.red
        case .info: return Color.blue
        }
    }
    
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

// MARK: - Button Configuration

struct ButtonConfig: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var playlist: String
    var icon: String
    var colorName: String
    var isFavorite: Bool  // true = favorites action, false = add to playlist

    var color: Color {
        switch colorName {
        case "pink": return .pink
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "yellow": return .yellow
        case "teal": return .teal
        default: return .blue
        }
    }

    static let availableColors = ["pink", "blue", "purple", "green", "orange", "red", "yellow", "teal"]
    static let availableIcons = [
        "heart.fill", "waveform", "bolt.fill", "star.fill", "music.note",
        "guitars.fill", "headphones", "mic.fill", "pianokeys", "beats.headphones",
        "flame.fill", "sparkles", "moon.fill", "sun.max.fill", "leaf.fill"
    ]

    static let defaults: [ButtonConfig] = [
        ButtonConfig(id: "btn1", title: "Favorite", playlist: "", icon: "heart.fill", colorName: "pink", isFavorite: true),
        ButtonConfig(id: "btn2", title: "Shazam", playlist: "My Shazam Tracks", icon: "waveform", colorName: "blue", isFavorite: false),
        ButtonConfig(id: "btn3", title: "Electronic", playlist: "Electronic Finds", icon: "bolt.fill", colorName: "purple", isFavorite: false),
    ]
}

class ButtonStore: ObservableObject {
    @Published var buttons: [ButtonConfig]

    private static var settingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".zenamp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    init() {
        if let data = try? Data(contentsOf: ButtonStore.settingsURL),
           let decoded = try? JSONDecoder().decode([ButtonConfig].self, from: data) {
            self.buttons = decoded
        } else {
            self.buttons = ButtonConfig.defaults
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(buttons) {
            try? data.write(to: ButtonStore.settingsURL)
        }
    }

    func resetToDefaults() {
        buttons = ButtonConfig.defaults
        save()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.uiScale) private var zoom
    @ObservedObject var store: ButtonStore
    @Binding var isShowing: Bool
    @State private var editingButtons: [ButtonConfig] = []
    @State private var playlists: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isShowing = false } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12 * zoom, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12 * zoom))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)

                Spacer()

                Text("Settings")
                    .font(.system(size: 13 * zoom, weight: .semibold))

                Spacer()

                // Invisible spacer to balance the header
                Button(action: {}) { Text("Back").font(.system(size: 12 * zoom)) }
                    .hidden()
            }
            .padding(.horizontal, 16 * zoom)
            .padding(.vertical, 12 * zoom)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                VStack(spacing: 16 * zoom) {
                    ForEach($editingButtons) { $button in
                        ButtonSettingsRow(config: $button, playlists: playlists)
                    }

                    // Skin picker
                    // Visualizer picker
                    HStack {
                        Image(systemName: AppState.shared.visualizerMode.icon)
                            .font(.system(size: 12 * zoom))
                            .foregroundColor(.secondary)
                        Text("Visualizer")
                            .font(.system(size: 12 * zoom))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { AppState.shared.visualizerMode },
                            set: { AppState.shared.visualizerMode = $0 }
                        )) {
                            ForEach(VisualizerMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                    .padding(12 * zoom)
                    .background(
                        RoundedRectangle(cornerRadius: 8 * zoom)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8 * zoom)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1 * zoom)
                    )
                }
                .padding(16 * zoom)
            }

            Divider()

            // Footer buttons
            HStack(spacing: 12 * zoom) {
                Button("Reset") {
                    editingButtons = ButtonConfig.defaults
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
                .font(.system(size: 11 * zoom))

                Spacer()

                Button("Save") {
                    store.buttons = editingButtons
                    store.save()
                    withAnimation(.easeInOut(duration: 0.2)) { isShowing = false }
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.blue)
                .font(.system(size: 12 * zoom, weight: .semibold))
            }
            .padding(.horizontal, 16 * zoom)
            .padding(.vertical, 10 * zoom)
        }
        .frame(width: 300 * zoom)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: 12 * zoom))
        .shadow(color: .black.opacity(0.2), radius: 8 * zoom, x: 0, y: 4 * zoom)
        .onAppear {
            editingButtons = store.buttons
            MusicController.fetchPlaylists { names in
                playlists = names
            }
        }
    }
}

struct ButtonSettingsRow: View {
    @Environment(\.uiScale) private var zoom
    @Binding var config: ButtonConfig
    var playlists: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * zoom) {
            // Preview
            HStack(spacing: 10 * zoom) {
                ZStack {
                    Circle()
                        .fill(config.color.opacity(0.15))
                        .frame(width: 30 * zoom, height: 30 * zoom)
                    Image(systemName: config.icon)
                        .font(.system(size: 13 * zoom, weight: .semibold))
                        .foregroundColor(config.color)
                }

                Text(config.title.isEmpty ? "Untitled" : config.title)
                    .font(.system(size: 12 * zoom, weight: .semibold))
                    .foregroundColor(config.title.isEmpty ? .secondary : .primary)

                Spacer()
            }

            // Title field
            HStack {
                Text("Label")
                    .font(.system(size: 10 * zoom))
                    .foregroundColor(.secondary)
                    .frame(width: 48 * zoom, alignment: .trailing)
                TextField("Button name", text: $config.title)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 11 * zoom))
            }

            // Action type
            HStack {
                Text("Action")
                    .font(.system(size: 10 * zoom))
                    .foregroundColor(.secondary)
                    .frame(width: 48 * zoom, alignment: .trailing)
                Picker("", selection: $config.isFavorite) {
                    Text("♥ Favorite Track").tag(true)
                    Text("Add to Playlist").tag(false)
                }
                .pickerStyle(MenuPickerStyle())
                .font(.system(size: 11 * zoom))
                .labelsHidden()
            }

            // Playlist picker (only for non-favorite)
            if !config.isFavorite {
                HStack {
                    Text("Playlist")
                        .font(.system(size: 10 * zoom))
                        .foregroundColor(.secondary)
                        .frame(width: 48 * zoom, alignment: .trailing)
                    if playlists.isEmpty {
                        TextField("Playlist name", text: $config.playlist)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 11 * zoom))
                    } else {
                        Picker("", selection: $config.playlist) {
                            Text("Select playlist...").tag("")
                            ForEach(playlists, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .font(.system(size: 11 * zoom))
                        .labelsHidden()
                    }
                }
            }

            // Color picker
            HStack {
                Text("Color")
                    .font(.system(size: 10 * zoom))
                    .foregroundColor(.secondary)
                    .frame(width: 48 * zoom, alignment: .trailing)
                HStack(spacing: 6 * zoom) {
                    ForEach(ButtonConfig.availableColors, id: \.self) { colorName in
                        Circle()
                            .fill(colorFor(colorName))
                            .frame(width: 16 * zoom, height: 16 * zoom)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: config.colorName == colorName ? 2 : 0)
                            )
                            .shadow(color: config.colorName == colorName ? colorFor(colorName).opacity(0.5) : .clear, radius: 3 * zoom)
                            .onTapGesture { config.colorName = colorName }
                    }
                }
            }

            // Icon picker
            HStack(alignment: .top) {
                Text("Icon")
                    .font(.system(size: 10 * zoom))
                    .foregroundColor(.secondary)
                    .frame(width: 48 * zoom, alignment: .trailing)
                    .padding(.top, 2 * zoom)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22 * zoom), spacing: 4 * zoom), count: 8), spacing: 4 * zoom) {
                    ForEach(ButtonConfig.availableIcons, id: \.self) { iconName in
                        Image(systemName: iconName)
                            .font(.system(size: 11 * zoom))
                            .frame(width: 22 * zoom, height: 22 * zoom)
                            .background(
                                RoundedRectangle(cornerRadius: 4 * zoom)
                                    .fill(config.icon == iconName ? config.color.opacity(0.2) : Color.clear)
                            )
                            .foregroundColor(config.icon == iconName ? config.color : .secondary)
                            .onTapGesture { config.icon = iconName }
                    }
                }
            }
        }
        .padding(12 * zoom)
        .background(
            RoundedRectangle(cornerRadius: 8 * zoom)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8 * zoom)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1 * zoom)
        )
    }

    func colorFor(_ name: String) -> Color {
        switch name {
        case "pink": return .pink
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "yellow": return .yellow
        case "teal": return .teal
        default: return .blue
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var buttonStore = ButtonStore()
    @ObservedObject private var appState = AppState.shared
    @State private var currentTrack: String = ""
    @State private var currentArtist: String = ""
    @State private var currentPlaylist: String = ""
    @State private var isPlaying: Bool = false
    @State private var bannerMessage: String = ""
    @State private var bannerType: BannerType = .info
    @State private var showBanner: Bool = false
    @State private var isLoading: [String: Bool] = [:]
    @State private var showSettings: Bool = false
    @State private var playlists: [String] = []
    @State private var shuffleEnabled: Bool = false
    @State private var albumArt: NSImage? = nil
    @State private var lastArtTrack: String = ""
    @State private var volume: Double = 50
    @State private var playerPosition: Double = 0
    @State private var trackDuration: Double = 0
    @State private var refreshesInFlight: Int = 0
    // Last position Music reported and when — the progress bar advances from this locally.
    @State private var positionAnchor: Double = 0
    @State private var positionAnchorDate: Date = Date()

    // Music posts this on track change / play / pause, so polling is only a safety net.
    private let playerInfoChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.Music.playerInfo"))
    let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    let positionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                SettingsView(store: buttonStore, isShowing: $showSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                WinampView(
                    buttonStore: buttonStore,
                    currentTrack: $currentTrack,
                    currentArtist: $currentArtist,
                    currentPlaylist: $currentPlaylist,
                    isPlaying: $isPlaying,
                    shuffleEnabled: $shuffleEnabled,
                    albumArt: $albumArt,
                    showBanner: $showBanner,
                    bannerMessage: $bannerMessage,
                    bannerType: $bannerType,
                    isLoading: $isLoading,
                    showSettings: $showSettings,
                    playlists: $playlists,
                    volume: $volume,
                    playerPosition: $playerPosition,
                    trackDuration: $trackDuration,
                    showExpandedArt: $appState.showExpandedArt,
                    showPlaylist: $appState.showPlaylist,
                    refreshTrackInfo: refreshTrackInfo,
                    resizeWindow: resizeWindow,
                    performAction: performAction,
                    showResult: showResultTuple
                )
            }

            // Playlist scroller — below the main player
            if appState.showPlaylist {
            PlaylistScrollerView(isShowing: $appState.showPlaylist, currentPlaylist: $currentPlaylist, currentTrack: $currentTrack, refreshTrackInfo: refreshTrackInfo)
                .frame(height: 250 * appState.zoomLevel)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }

            if appState.showSearch {
                SearchPanelView(isShowing: $appState.showSearch)
                    .frame(height: 300 * appState.zoomLevel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } // end VStack
        // Sizes are multiplied by the zoom rather than using scaleEffect, which
        // stretches the 1x rasterised layers and blurs text and icons.
        .environment(\.uiScale, CGFloat(appState.zoomLevel))
        .frame(
            width: 300 * appState.zoomLevel,
            height: (520 + (appState.showExpandedArt ? 300 : 0) + (appState.showPlaylist ? 250 : 0) + (appState.showSearch ? 300 : 0)) * appState.zoomLevel,
            alignment: .topLeading
        )
        .animation(.easeInOut(duration: 0.25), value: appState.showPlaylist)
        .animation(.easeInOut(duration: 0.25), value: appState.showSearch)
        // Panels can also be closed from their own X buttons, so size the window here.
        .onChange(of: appState.showPlaylist) { _, _ in resizeWindow() }
        .onChange(of: appState.showSearch) { _, _ in resizeWindow() }
        .onAppear {
            refreshTrackInfo()
            MusicController.fetchPlaylists { names in playlists = names }
            MusicController.getShuffleState { enabled in shuffleEnabled = enabled }
            MusicController.getVolume { v in volume = v }
        }
        .onReceive(playerInfoChanged) { note in
            // Music playing again (from Music itself, the playlist menu or panel) takes back the transport.
            if note.userInfo?["Player State"] as? String == "Playing" {
                CatalogPlayer.shared.deactivate()
            }
            guard !MusicController.isJumping else { return }
            refreshTrackInfo()
        }
        .onReceive(CatalogPlayer.shared.changed) { _ in
            if CatalogPlayer.shared.isActive { refreshTrackInfo() }
        }
        .onReceive(timer) { _ in
            // Fallback resync; skipped while a refresh is still running so a slow
            // Music can't stack up scripts, and while nobody can see the window.
            guard refreshesInFlight == 0, appState.isWindowVisible else { return }
            refreshTrackInfo()
        }
        .onReceive(positionTimer) { _ in
            guard isPlaying, trackDuration > 0 else { return }
            let estimated = positionAnchor + Date().timeIntervalSince(positionAnchorDate)
            if estimated >= trackDuration {
                playerPosition = trackDuration
                // Track should have ended — pick up whatever is playing now.
                if refreshesInFlight == 0 { refreshTrackInfo() }
            } else {
                playerPosition = estimated
            }
        }
        .onChange(of: appState.isWindowVisible) { _, visible in
            if visible { refreshTrackInfo() }
        }
    }


    func resizeWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = AppDelegate.shared?.mainWindow {
                let zoom = CGFloat(self.appState.zoomLevel)
                let baseWidth: CGFloat = 300 * zoom
                let artHeight: CGFloat = self.appState.showExpandedArt ? 300 * zoom : 0
                let baseHeight: CGFloat = 520 * zoom
                let playlistHeight: CGFloat = self.appState.showPlaylist ? 250 * zoom : 0
                let searchHeight: CGFloat = self.appState.showSearch ? 300 * zoom : 0
                let targetWidth = baseWidth
                let targetHeight = baseHeight + artHeight + playlistHeight + searchHeight

                var frame = window.frame
                // Keep top-left anchored — expand downward
                let heightDiff = targetHeight - frame.height
                frame.origin.y -= heightDiff
                frame.size.width = targetWidth
                frame.size.height = targetHeight
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }

    func refreshTrackInfo() {
        if CatalogPlayer.shared.isActive {
            apply(CatalogPlayer.shared.trackInfo(), fetchArtwork: CatalogPlayer.shared.fetchArtwork)
            return
        }
        refreshesInFlight += 1
        MusicController.getCurrentTrackInfo { info in
            refreshesInFlight -= 1
            // A catalog pick may have started while this script ran.
            guard !CatalogPlayer.shared.isActive else { return }
            apply(info, fetchArtwork: MusicController.fetchArtwork)
        }
    }

    private func apply(_ info: MusicController.TrackInfo?, fetchArtwork: @escaping (@escaping (NSImage?) -> Void) -> Void) {
        withAnimation(.easeInOut(duration: 0.2)) {
            currentTrack = info?.name ?? ""
            currentArtist = info?.artist ?? ""
            currentPlaylist = info?.playlist ?? ""
            isPlaying = info?.isPlaying ?? false
        }
        positionAnchor = info?.position ?? 0
        positionAnchorDate = Date()
        playerPosition = info?.position ?? 0
        trackDuration = info?.duration ?? 0
        // Only fetch artwork when track changes — crossfade
        let trackKey = (info?.name ?? "") + (info?.artist ?? "")
        if trackKey != lastArtTrack {
            lastArtTrack = trackKey
            if info != nil {
                fetchArtwork { image in
                    withAnimation(.easeInOut(duration: 0.6)) {
                        albumArt = image
                    }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    albumArt = nil
                }
            }
        }
    }

    func performAction(key: String, action: () -> Void) {
        isLoading[key] = true
        action()
    }

    func showResultTuple(success: Bool, message: String) {
        showResult(success: success, message: message)
    }

    func showResult(success: Bool, message: String) {
        // Reset all loading
        isLoading = [:]

        withAnimation(.easeInOut(duration: 0.25)) {
            bannerMessage = message
            bannerType = success ? .success : .error
            showBanner = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showBanner = false
            }
        }

        // Refresh track info
        refreshTrackInfo()
    }
}

// MARK: - Action Button

struct ActionButton: View {
    @Environment(\.uiScale) private var zoom
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12 * zoom) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 36 * zoom, height: 36 * zoom)
                    
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5 * zoom)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15 * zoom, weight: .semibold))
                            .foregroundColor(color)
                    }
                }
                
                VStack(alignment: .leading, spacing: 1 * zoom) {
                    Text(title)
                        .font(.system(size: 13 * zoom, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 10 * zoom))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16 * zoom))
                    .foregroundColor(color.opacity(isHovered ? 1.0 : 0.5))
            }
            .padding(.horizontal, 12 * zoom)
            .padding(.vertical, 10 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 10 * zoom)
                    .fill(isPressed ? color.opacity(0.1) : (isHovered ? color.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10 * zoom)
                    .stroke(isHovered ? color.opacity(0.3) : Color.clear, lineWidth: 1 * zoom)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Audio Waveform Visualizer

/// Drawn in a single Canvas driven by a TimelineView: no timer, no published state,
/// so each frame redraws only this view — and nothing at all while paused.
struct AudioWaveformView: View {
    var isPlaying: Bool
    var style: WaveformStyle

    enum WaveformStyle {
        case bars       // Classic EQ bars
        case mirror     // Mirrored waveform
        case glow       // Glowing line

        var colors: [Color] {
            switch self {
            case .bars: return [Color.green, Color.yellow, Color.red]
            case .mirror: return [Color.cyan, Color.blue, Color.purple]
            case .glow: return [Color.purple, Color.pink, Color.orange]
            }
        }
    }

    private static let barCount = 32
    private static let barSpacing: CGFloat = 2
    private static let idleLevels = [CGFloat](repeating: 0.05, count: barCount)

    private static func levels(at time: TimeInterval) -> [CGFloat] {
        let phase = time * 2.25
        return (0..<barCount).map { i in
            let x = Double(i) / Double(barCount)
            // Combine multiple sine waves for organic look
            let wave1 = sin(x * 4.0 + phase) * 0.3
            let wave2 = sin(x * 7.0 + phase * 1.3) * 0.2
            let wave3 = sin(x * 13.0 + phase * 0.7) * 0.15
            let wave4 = cos(x * 3.0 + phase * 1.8) * 0.1
            let noise = Double.random(in: -0.1...0.1)
            let combined = (wave1 + wave2 + wave3 + wave4 + noise + 0.5)
            return CGFloat(max(0.05, min(1.0, combined)))
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !isPlaying)) { timeline in
            let levels = isPlaying
                ? Self.levels(at: timeline.date.timeIntervalSinceReferenceDate)
                : Self.idleLevels
            Canvas { context, size in
                switch style {
                case .bars: drawBars(levels, in: context, size: size)
                case .mirror: drawMirror(levels, in: context, size: size)
                case .glow: drawGlow(levels, in: context, size: size)
                }
            }
        }
    }

    private func barWidth(for count: Int, in size: CGSize) -> CGFloat {
        max(1, (size.width - Self.barSpacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private func drawBars(_ levels: [CGFloat], in context: GraphicsContext, size: CGSize) {
        let width = barWidth(for: levels.count, in: size)
        let gradient = Gradient(colors: style.colors)
        for (i, level) in levels.enumerated() {
            let height = size.height * level
            let rect = CGRect(x: CGFloat(i) * (width + Self.barSpacing), y: size.height - height, width: width, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .linearGradient(gradient, startPoint: CGPoint(x: rect.midX, y: rect.maxY), endPoint: CGPoint(x: rect.midX, y: rect.minY))
            )
        }
    }

    private func drawMirror(_ levels: [CGFloat], in context: GraphicsContext, size: CGSize) {
        let width = barWidth(for: levels.count, in: size)
        let gradient = Gradient(colors: style.colors)
        let reflection = Gradient(colors: style.colors.map { $0.opacity(0.4) })
        let midY = size.height / 2
        for (i, level) in levels.enumerated() {
            let x = CGFloat(i) * (width + Self.barSpacing)
            let upHeight = size.height * 0.5 * level
            let up = CGRect(x: x, y: midY - 0.5 - upHeight, width: width, height: upHeight)
            context.fill(
                Path(roundedRect: up, cornerRadius: 1),
                with: .linearGradient(gradient, startPoint: CGPoint(x: up.midX, y: up.maxY), endPoint: CGPoint(x: up.midX, y: up.minY))
            )
            let down = CGRect(x: x, y: midY + 0.5, width: width, height: size.height * 0.3 * level)
            context.fill(
                Path(roundedRect: down, cornerRadius: 1),
                with: .linearGradient(reflection, startPoint: CGPoint(x: down.midX, y: down.minY), endPoint: CGPoint(x: down.midX, y: down.maxY))
            )
        }
    }

    private func drawGlow(_ levels: [CGFloat], in context: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let midY = h / 2
        var path = Path()
        for (i, level) in levels.enumerated() {
            let x = w * CGFloat(i) / CGFloat(levels.count)
            let y = midY + (level - 0.5) * h * 0.8
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                let prevX = w * CGFloat(i - 1) / CGFloat(levels.count)
                let cpX = (prevX + x) / 2
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: cpX, y: path.currentPoint?.y ?? midY),
                    control2: CGPoint(x: cpX, y: y)
                )
            }
        }

        // Glow effect - draw multiple times with decreasing opacity
        for blur in stride(from: 6.0, through: 0, by: -2) {
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: style.colors),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: w, y: 0)
                ),
                lineWidth: 2 + blur
            )
        }
    }
}

// MARK: - Volume Slider

// MARK: - Progress Bar

struct ProgressBarView: View {
    @Environment(\.uiScale) private var zoom
    var position: Double
    var duration: Double
    var accentColor: Color = .white

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 2 * zoom) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 2 * zoom)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 4 * zoom)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 2 * zoom)
                        .fill(accentColor)
                        .frame(width: geo.size.width * progress, height: 4 * zoom)

                    // Scrubber dot
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8 * zoom, height: 8 * zoom)
                        .offset(x: max(0, geo.size.width * progress - 4 * zoom))
                }
            }
            .frame(height: 8 * zoom)

            HStack {
                Text(formatTime(position))
                    .font(.system(size: 9 * zoom, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("-\(formatTime(max(0, duration - position)))")
                    .font(.system(size: 9 * zoom, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct VolumeSliderView: View {
    @Environment(\.uiScale) private var zoom
    @Binding var volume: Double
    var accentColor: Color = .white

    var body: some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 9 * zoom))
                .foregroundColor(accentColor.opacity(0.6))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2 * zoom)
                        .fill(accentColor.opacity(0.15))
                        .frame(height: 4 * zoom)

                    RoundedRectangle(cornerRadius: 2 * zoom)
                        .fill(accentColor.opacity(0.6))
                        .frame(width: geo.size.width * volume / 100, height: 4 * zoom)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newVol = Double(value.location.x / geo.size.width) * 100
                            volume = max(0, min(100, newVol))
                            MusicController.setVolume(volume)
                        }
                )
            }
            .frame(height: 16 * zoom)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 9 * zoom))
                .foregroundColor(accentColor.opacity(0.6))
        }
    }
}

// MARK: - Skin Definitions

// MARK: - Playlist Scroller View

struct PlaylistTrack: Identifiable, Equatable {
    let id: Int
    let dbID: String  // Apple Music database ID for reliable playback
    let name: String
    let artist: String
    let duration: String
    var isPlaying: Bool
}

struct PlaylistTheme {
    let primary: Color
    let secondary: Color
    let bg: Color
    let rowBg1: Color
    let rowBg2: Color
    let activeBg: Color
    let border: Color
    let titleBg1: Color
    let titleBg2: Color
    let listBg: Color
    let bottomBg: Color
    let isMonospaced: Bool
    let isUppercased: Bool

    static let zenamp = PlaylistTheme(
        primary: Color(red: 0, green: 1, blue: 0),
        secondary: Color(red: 1, green: 0.67, blue: 0),
        bg: Color(red: 0.1, green: 0.1, blue: 0.12),
        rowBg1: Color.black.opacity(0.3),
        rowBg2: Color.black.opacity(0.15),
        activeBg: Color(red: 0, green: 1, blue: 0).opacity(0.08),
        border: Color(red: 0.25, green: 0.25, blue: 0.3),
        titleBg1: Color(red: 0.05, green: 0.05, blue: 0.08),
        titleBg2: Color(red: 0.12, green: 0.12, blue: 0.15),
        listBg: Color.black.opacity(0.5),
        bottomBg: Color.black.opacity(0.3),
        isMonospaced: true,
        isUppercased: true
    )

    static let napster = PlaylistTheme(
        primary: Color(red: 0.18, green: 0.30, blue: 0.55),
        secondary: Color(red: 0.3, green: 0.3, blue: 0.3),
        bg: Color(red: 0.88, green: 0.87, blue: 0.86),
        rowBg1: Color.white,
        rowBg2: Color(red: 0.94, green: 0.94, blue: 0.96),
        activeBg: Color(red: 0.18, green: 0.30, blue: 0.55).opacity(0.12),
        border: Color(red: 0.50, green: 0.50, blue: 0.52),
        titleBg1: Color(red: 0.18, green: 0.30, blue: 0.55),
        titleBg2: Color(red: 0.35, green: 0.50, blue: 0.75),
        listBg: Color.white,
        bottomBg: Color(red: 0.82, green: 0.82, blue: 0.84),
        isMonospaced: false,
        isUppercased: false
    )

    static let vaporwave = PlaylistTheme(
        primary: Color(red: 1, green: 0.4, blue: 0.8),
        secondary: Color(red: 0.4, green: 0.8, blue: 1),
        bg: Color(red: 0.12, green: 0.05, blue: 0.18),
        rowBg1: Color(red: 0.15, green: 0.05, blue: 0.2).opacity(0.8),
        rowBg2: Color(red: 0.12, green: 0.04, blue: 0.16).opacity(0.8),
        activeBg: Color(red: 1, green: 0.4, blue: 0.8).opacity(0.1),
        border: Color(red: 1, green: 0.4, blue: 0.8).opacity(0.3),
        titleBg1: Color(red: 0.15, green: 0.05, blue: 0.2),
        titleBg2: Color(red: 0.2, green: 0.08, blue: 0.28),
        listBg: Color(red: 0.08, green: 0.02, blue: 0.12),
        bottomBg: Color.black.opacity(0.4),
        isMonospaced: false,
        isUppercased: true
    )

    static let minimal = PlaylistTheme(
        primary: Color.primary,
        secondary: Color.secondary,
        bg: Color(NSColor.windowBackgroundColor),
        rowBg1: Color(NSColor.controlBackgroundColor),
        rowBg2: Color(NSColor.controlBackgroundColor).opacity(0.5),
        activeBg: Color.accentColor.opacity(0.1),
        border: Color.secondary.opacity(0.2),
        titleBg1: Color(NSColor.controlBackgroundColor),
        titleBg2: Color(NSColor.controlBackgroundColor),
        listBg: Color(NSColor.textBackgroundColor),
        bottomBg: Color(NSColor.controlBackgroundColor),
        isMonospaced: false,
        isUppercased: false
    )

    static let modern = minimal
}

struct PlaylistScrollerView: View {
    @Environment(\.uiScale) private var zoom
    @Binding var isShowing: Bool
    @Binding var currentPlaylist: String
    @Binding var currentTrack: String
    @State private var tracks: [PlaylistTrack] = []
    @State private var isLoading = true
    @State private var jumpingToTrackID: Int?
    var refreshTrackInfo: () -> Void
    @ObservedObject var appState = AppState.shared

    var theme: PlaylistTheme { .zenamp }

    var body: some View {
        VStack(spacing: 0) {
            plTitleBar
            trackListView
            plBottomBar
        }
        .frame(width: 300 * zoom)
        .background(theme.bg)
        .border(theme.border, width: 1 * zoom)
        .clipShape(RoundedRectangle(cornerRadius: 4 * zoom))
        .onAppear { loadTracks() }
        .onChange(of: currentPlaylist) { _, _ in
            // The list follows whatever Music is playing from.
            if !MusicController.isJumping { loadTracks() }
        }
        .onChange(of: currentTrack) { newTrack in
            // Just update the highlight, don't re-fetch the entire playlist
            for i in tracks.indices {
                let isNowPlaying = tracks[i].name == newTrack
                if tracks[i].isPlaying != isNowPlaying {
                    tracks[i] = PlaylistTrack(id: tracks[i].id, dbID: tracks[i].dbID, name: tracks[i].name, artist: tracks[i].artist, duration: tracks[i].duration, isPlaying: isNowPlaying)
                }
            }
        }
    }

    var plTitleBar: some View {
        let titleText = currentPlaylist.isEmpty ? "Playlist" : currentPlaylist
        return HStack {
            Image(systemName: "list.bullet")
                .font(.system(size: 8 * zoom))
                .foregroundColor(titleBarFg)
            Text(theme.isUppercased ? titleText.uppercased() : titleText)
                .font(.system(size: 9 * zoom, weight: .bold, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(titleBarFg)
                .lineLimit(1)
            Text("[\(tracks.count) tracks]")
                .font(.system(size: 8 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(titleBarFg.opacity(0.6))
            Spacer()
            Button(action: { loadTracks() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8 * zoom))
                    .foregroundColor(titleBarFg.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isShowing = false }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8 * zoom))
                    .foregroundColor(titleBarFg.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 5 * zoom)
        .background(
            LinearGradient(
                colors: [theme.titleBg1, theme.titleBg2],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    var titleBarFg: Color { theme.primary }

    var trackListView: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(0.6 * zoom)
                    Text(theme.isUppercased ? "LOADING..." : "Loading...")
                        .font(.system(size: 8 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                        .foregroundColor(theme.primary.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.listBg)
            } else if tracks.isEmpty {
                VStack {
                    Text(theme.isUppercased ? "NO TRACKS" : "No tracks")
                        .font(.system(size: 10 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                        .foregroundColor(theme.primary.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.listBg)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tracks) { track in
                                trackRow(track)
                            }
                        }
                    }
                    .background(theme.listBg)
                    .onAppear {
                        if let playing = tracks.first(where: { $0.isPlaying }) {
                            proxy.scrollTo(playing.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    func trackRow(_ track: PlaylistTrack) -> some View {
        let trackText = "\(track.artist) - \(track.name)"
        return HStack(spacing: 6 * zoom) {
            Text(String(format: "%02d", track.id + 1))
                .font(.system(size: 8 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(track.isPlaying ? theme.secondary : theme.primary.opacity(0.35))
                .frame(width: 18 * zoom, alignment: .trailing)

            if jumpingToTrackID == track.id {
                ProgressView()
                    .scaleEffect(0.3 * zoom)
                    .frame(width: 10 * zoom, height: 10 * zoom)
            } else if track.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 6 * zoom))
                    .foregroundColor(theme.primary)
                    .frame(width: 10 * zoom)
            } else {
                Color.clear.frame(width: 10 * zoom, height: 1 * zoom)
            }

            Text(theme.isUppercased ? trackText.uppercased() : trackText)
                .font(.system(size: 9 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(track.isPlaying ? theme.primary : theme.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(track.duration)
                .font(.system(size: 8 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(track.isPlaying ? theme.secondary : theme.primary.opacity(0.35))
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 3 * zoom)
        .background(track.isPlaying ? theme.activeBg : (track.id % 2 == 0 ? theme.rowBg1 : theme.rowBg2))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !MusicController.isJumping,
                  let pid = MusicController.currentPlaylistPersistentID else { return }
            jumpingToTrackID = track.id
            MusicController.jumpToTrack(dbID: track.dbID, index: track.id + 1, playlistPersistentID: pid) { _ in
                jumpingToTrackID = nil
                refreshTrackInfo()
            }
        }
    }

    var plBottomBar: some View {
        HStack {
            if let playing = tracks.first(where: { $0.isPlaying }) {
                let t = theme.isUppercased ? "▶ \(playing.name.uppercased())" : "▶ \(playing.name)"
                Text(t)
                    .font(.system(size: 7 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                    .foregroundColor(theme.primary.opacity(0.6))
                    .lineLimit(1)
            } else {
                Text(theme.isUppercased ? "STOPPED" : "Stopped")
                    .font(.system(size: 7 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                    .foregroundColor(theme.primary.opacity(0.4))
            }
            Spacer()
            Text(totalTimeString)
                .font(.system(size: 7 * zoom, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(theme.secondary.opacity(0.6))
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 4 * zoom)
        .background(theme.bottomBg)
    }

    var totalTimeString: String {
        let totalSeconds = tracks.reduce(0) { sum, t in
            let parts = t.duration.components(separatedBy: ":")
            let mins = Int(parts.first ?? "0") ?? 0
            let secs = Int(parts.last ?? "0") ?? 0
            return sum + mins * 60 + secs
        }
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func loadTracks() {
        isLoading = true
        MusicController.fetchCurrentPlaylistTracks { result in
            defer { isLoading = false }
            // A failed fetch (Music busy, nothing playing) keeps the list we have
            // rather than blanking it.
            if result.isEmpty && !tracks.isEmpty { return }
            tracks = result.enumerated().map { PlaylistTrack(id: $0.offset, dbID: $0.element.dbID, name: $0.element.name, artist: $0.element.artist, duration: $0.element.duration, isPlaying: $0.element.isPlaying) }
        }
    }
}

// MARK: - Apple Music Search

struct CatalogResult: Identifiable {
    enum Kind { case song, album, artist }
    let id: Int
    let kind: Kind
    let name: String
    let detail: String  // artist · album
    let extra: String   // length, year · tracks, or genre
    let url: URL?
    let catalogID: String?  // iTunes Search IDs are Apple Music catalog IDs

    var mark: String {
        switch kind {
        case .song: return "♪"
        case .album: return "◉"
        case .artist: return "★"
        }
    }
}

/// Apple's public iTunes Search API: no account or key, ~20 requests a minute.
enum CatalogSearch {
    enum Scope: String, CaseIterable {
        case all = "ALL", songs = "SONGS", albums = "ALBUMS", artists = "ARTISTS"

        var entity: String {
            switch self {
            case .all: return "musicArtist,album,song"
            case .songs: return "song"
            case .albums: return "album"
            case .artists: return "musicArtist"
            }
        }
    }

    enum Failure: Error {
        case rateLimited
        case http(Int)
    }

    private struct Response: Decodable {
        let results: [Item]
    }

    private struct Item: Decodable {
        let wrapperType: String?
        let kind: String?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Int?
        let releaseDate: String?
        let trackCount: Int?
        let primaryGenreName: String?
        let trackViewUrl: String?
        let collectionViewUrl: String?
        let artistLinkUrl: String?
        let trackId: Int?
        let collectionId: Int?
        let artistId: Int?
    }

    /// Storefront for the Mac's region, e.g. "us".
    static let country = (Locale.current.region?.identifier ?? "US").lowercased()

    static func search(_ term: String, scope: Scope) async throws -> [CatalogResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: scope.entity),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "50"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw [403, 429].contains(http.statusCode) ? Failure.rateLimited : Failure.http(http.statusCode)
        }
        let items = try JSONDecoder().decode(Response.self, from: data).results
        return items.enumerated().compactMap { result(from: $0.element, id: $0.offset) }
    }

    private static func result(from item: Item, id: Int) -> CatalogResult? {
        let artist = item.artistName ?? ""
        switch item.wrapperType {
        case "track" where item.kind == "song":
            let ms = item.trackTimeMillis ?? 0
            let length = ms > 0 ? "\(ms / 60000):\(String(format: "%02d", ms / 1000 % 60))" : ""
            let detail = [artist, item.collectionName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return CatalogResult(id: id, kind: .song, name: item.trackName ?? "", detail: detail,
                                 extra: length, url: item.trackViewUrl.flatMap(URL.init(string:)),
                                 catalogID: item.trackId.map(String.init))
        case "collection":
            let year = String((item.releaseDate ?? "").prefix(4))
            let tracks = item.trackCount.map { "\($0) track\($0 == 1 ? "" : "s")" } ?? ""
            let extra = [year, tracks].filter { !$0.isEmpty }.joined(separator: " · ")
            return CatalogResult(id: id, kind: .album, name: item.collectionName ?? "", detail: artist,
                                 extra: extra, url: item.collectionViewUrl.flatMap(URL.init(string:)),
                                 catalogID: item.collectionId.map(String.init))
        case "artist":
            return CatalogResult(id: id, kind: .artist, name: artist, detail: "",
                                 extra: item.primaryGenreName ?? "", url: item.artistLinkUrl.flatMap(URL.init(string:)),
                                 catalogID: item.artistId.map(String.init))
        default:
            return nil
        }
    }
}

/// Plays Apple Music catalog picks inside ZenAmp. On macOS MusicKit can't drive the
/// Music app (SystemMusicPlayer is unavailable there), so ZenAmp plays them itself
/// and the transport follows this player until Music starts playing again.
@MainActor
final class CatalogPlayer {
    static let shared = CatalogPlayer()

    enum Failure: Error { case notAuthorized, notFound }

    private let player = ApplicationMusicPlayer.shared
    /// True from a catalog pick until Music takes over again.
    private(set) var isActive = false
    /// Fires when the queue or playback state changes.
    let changed = PassthroughSubject<Void, Never>()
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        // objectWillChange fires before the change lands, so deliver on the next pass.
        player.state.objectWillChange
            .merge(with: player.queue.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.changed.send() }
            .store(in: &subscriptions)
    }

    /// A song plays on through the rest of its album, an album from the top,
    /// and an artist through their top songs.
    func play(_ result: CatalogResult) async throws {
        guard let id = result.catalogID else { throw Failure.notFound }
        if MusicAuthorization.currentStatus != .authorized {
            guard await MusicAuthorization.request() == .authorized else { throw Failure.notAuthorized }
        }
        let itemID = MusicItemID(id)
        switch result.kind {
        case .song:
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: itemID)
            request.properties = [.albums]
            guard let song = try await request.response().items.first else { throw Failure.notFound }
            // Queue from the song to the end of its album. Queue(for:startingAt:) fails
            // to prepare with album tracks ("unexpected start item"), so drop the head instead.
            let rest = try await song.albums?.first?.with([.tracks]).tracks?.drop { $0.id != song.id }
            if let rest, !rest.isEmpty {
                player.queue = ApplicationMusicPlayer.Queue(for: Array(rest))
            } else {
                player.queue = [song]
            }
        case .album:
            let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: itemID)
            guard let album = try await request.response().items.first else { throw Failure.notFound }
            player.queue = [album]
        case .artist:
            var request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: itemID)
            request.properties = [.topSongs]
            guard let songs = try await request.response().items.first?.topSongs, !songs.isEmpty else {
                throw Failure.notFound
            }
            player.queue = ApplicationMusicPlayer.Queue(for: songs)
        }
        MusicController.pause()
        isActive = true
        do {
            try await player.play()
        } catch {
            isActive = false
            throw error
        }
        changed.send()
    }

    /// Hands the transport back to Music.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        player.stop()
    }

    var isPlaying: Bool { player.state.playbackStatus == .playing }

    func playPause() {
        if isPlaying {
            player.pause()
        } else {
            Task { try? await player.play() }
        }
    }

    func next() { Task { try? await player.skipToNextEntry() } }

    func previous() { Task { try? await player.skipToPreviousEntry() } }

    func trackInfo() -> MusicController.TrackInfo? {
        guard let entry = player.queue.currentEntry else { return nil }
        var album = "APPLE MUSIC"
        var duration: Double = 0
        if case .song(let song) = entry.item {
            album = song.albumTitle ?? album
            duration = song.duration ?? 0
        }
        return MusicController.TrackInfo(
            name: entry.title,
            artist: entry.subtitle ?? "",
            playlist: album,
            isPlaying: isPlaying,
            position: player.playbackTime,
            duration: duration
        )
    }

    func fetchArtwork(completion: @escaping (NSImage?) -> Void) {
        guard let url = player.queue.currentEntry?.artwork?.url(width: 256, height: 256) else {
            completion(nil)
            return
        }
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            completion(data.flatMap(NSImage.init(data:)))
        }
    }
}

/// Sends transport presses to whichever player is active.
@MainActor
enum Transport {
    static func playPause(completion: @escaping () -> Void) {
        if CatalogPlayer.shared.isActive {
            CatalogPlayer.shared.playPause()
            completion()
        } else {
            MusicController.playPause(completion: completion)
        }
    }

    static func next(completion: @escaping () -> Void) {
        // With the search panel open, NEXT/PREV walk the search results.
        if AppState.shared.showSearch, SearchModel.shared.playAdjacent(1) {
            completion()
        } else if CatalogPlayer.shared.isActive {
            CatalogPlayer.shared.next()
            completion()
        } else {
            MusicController.nextTrack(completion: completion)
        }
    }

    static func previous(completion: @escaping () -> Void) {
        if AppState.shared.showSearch, SearchModel.shared.playAdjacent(-1) {
            completion()
        } else if CatalogPlayer.shared.isActive {
            CatalogPlayer.shared.previous()
            completion()
        } else {
            MusicController.previousTrack(completion: completion)
        }
    }
}

/// Search state lives here rather than in the panel so the query and results
/// survive closing the panel, and the transport can step through results.
@MainActor
final class SearchModel: ObservableObject {
    static let shared = SearchModel()

    @Published var query = ""
    @Published var scope: CatalogSearch.Scope = .all
    @Published var results: [CatalogResult] = []
    @Published var selection: Int?
    @Published var status = "TYPE TO SEARCH APPLE MUSIC"
    /// Bumped by the FIND button to focus the field and select its text.
    @Published var focusRequest = 0
    private var cache: [String: [CatalogResult]] = [:]
    private var shownKey = ""

    func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            shownKey = ""
            show([], status: "TYPE TO SEARCH APPLE MUSIC")
            return
        }
        let key = "\(scope.rawValue)|\(term.lowercased())"
        // Reopening the panel reruns the search task; keep the list and selection as they were.
        guard key != shownKey else { return }
        if let cached = cache[key] {
            shownKey = key
            show(cached, status: summary(cached))
            return
        }
        // Debounce: a keystroke within this window cancels the task before it searches.
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        status = "SEARCHING…"
        do {
            let found = try await CatalogSearch.search(term, scope: scope)
            guard !Task.isCancelled else { return }
            cache[key] = found
            shownKey = key
            show(found, status: summary(found))
        } catch CatalogSearch.Failure.rateLimited {
            status = "APPLE RATE LIMIT — WAIT A FEW SECONDS"
        } catch {
            if !Task.isCancelled { status = "SEARCH FAILED" }
        }
    }

    private func show(_ found: [CatalogResult], status newStatus: String) {
        results = found
        selection = found.first?.id
        status = newStatus
    }

    private func summary(_ found: [CatalogResult]) -> String {
        found.isEmpty ? "NO MATCHES" : "\(found.count) RESULT\(found.count == 1 ? "" : "S")"
    }

    func moveSelection(_ step: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? -step
        let next = min(max(current + step, 0), results.count - 1)
        selection = results[next].id
    }

    /// Plays the result `step` away from the selection. False when there's nothing to step to.
    func playAdjacent(_ step: Int) -> Bool {
        guard let current = results.firstIndex(where: { $0.id == selection }),
              results.indices.contains(current + step) else { return false }
        let result = results[current + step]
        selection = result.id
        play(result)
        return true
    }

    func playSelection() {
        if let result = results.first(where: { $0.id == selection }) { play(result) }
    }

    func play(_ result: CatalogResult) {
        selection = result.id
        status = "LOADING…"
        Task {
            do {
                try await CatalogPlayer.shared.play(result)
                status = "PLAYING IN ZENAMP"
            } catch CatalogPlayer.Failure.notAuthorized {
                status = "ALLOW APPLE MUSIC IN SYSTEM SETTINGS › PRIVACY"
            } catch {
                status = "COULDN'T PLAY THAT ONE"
            }
        }
    }
}

struct SearchPanelView: View {
    @Environment(\.uiScale) private var zoom
    @Binding var isShowing: Bool
    @ObservedObject private var model = SearchModel.shared
    @FocusState private var fieldFocused: Bool

    var theme: PlaylistTheme { .zenamp }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            searchField
            scopeBar
            resultsList
            bottomBar
        }
        .frame(width: 300 * zoom)
        .background(theme.bg)
        .border(theme.border, width: 1 * zoom)
        .clipShape(RoundedRectangle(cornerRadius: 4 * zoom))
        .onAppear(perform: focusField)
        .onChange(of: model.focusRequest) { _, _ in focusField() }
        // Restarts (cancelling the previous run) whenever the query or scope changes.
        .task(id: "\(model.scope.rawValue)|\(model.query)") { await model.search() }
    }

    /// Focuses the field with its text selected, so typing replaces the last search.
    private func focusField() {
        fieldFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        }
    }

    var titleBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 8 * zoom))
            Text("SEARCH APPLE MUSIC")
                .font(.system(size: 9 * zoom, weight: .bold, design: .monospaced))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8 * zoom))
                    .opacity(0.7)
            }.buttonStyle(PlainButtonStyle())
        }
        .foregroundColor(theme.primary)
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 5 * zoom)
        .background(LinearGradient(colors: [theme.titleBg1, theme.titleBg2], startPoint: .leading, endPoint: .trailing))
    }

    var searchField: some View {
        TextField("", text: $model.query, prompt: Text("ARTIST, ALBUM OR SONG").foregroundColor(theme.primary.opacity(0.3)))
            .textFieldStyle(.plain)
            .font(.system(size: 10 * zoom, design: .monospaced))
            .foregroundColor(theme.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 6 * zoom)
            .padding(.vertical, 4 * zoom)
            .background(Color.black.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 2 * zoom).stroke(theme.primary.opacity(0.3), lineWidth: 1 * zoom))
            .padding(.horizontal, 6 * zoom)
            .padding(.top, 6 * zoom)
            .onSubmit { model.playSelection() }
            .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            .onExitCommand {
                if model.query.isEmpty { close() } else { model.query = "" }
            }
    }

    var scopeBar: some View {
        HStack(spacing: 10 * zoom) {
            ForEach(CatalogSearch.Scope.allCases, id: \.self) { item in
                Text(item.rawValue)
                    .font(.system(size: 7 * zoom, weight: .bold, design: .monospaced))
                    .foregroundColor(item == model.scope ? theme.secondary : theme.primary.opacity(0.45))
                    .contentShape(Rectangle())
                    .onTapGesture { model.scope = item }
            }
            Spacer()
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 5 * zoom)
    }

    var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { result in
                        resultRow(result)
                            .id(result.id)
                    }
                }
            }
            .background(theme.listBg)
            .onAppear {
                if let selected = model.selection { proxy.scrollTo(selected) }
            }
            .onChange(of: model.selection) { _, selected in
                if let selected { proxy.scrollTo(selected) }
            }
        }
    }

    func resultRow(_ result: CatalogResult) -> some View {
        let isSelected = result.id == model.selection
        return HStack(alignment: .top, spacing: 6 * zoom) {
            Text(result.mark)
                .font(.system(size: 9 * zoom))
                .foregroundColor(theme.secondary)
                .frame(width: 10 * zoom)
            VStack(alignment: .leading, spacing: 1 * zoom) {
                Text(result.name.uppercased())
                    .font(.system(size: 9 * zoom, design: .monospaced))
                    .foregroundColor(isSelected ? theme.primary : theme.primary.opacity(0.8))
                    .lineLimit(1)
                if !result.detail.isEmpty {
                    Text(result.detail.uppercased())
                        .font(.system(size: 7 * zoom, design: .monospaced))
                        .foregroundColor(theme.primary.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4 * zoom)
            Text(result.extra.uppercased())
                .font(.system(size: 7 * zoom, design: .monospaced))
                .foregroundColor(theme.secondary.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 3 * zoom)
        .background(isSelected ? theme.activeBg : (result.id % 2 == 0 ? theme.rowBg1 : theme.rowBg2))
        .contentShape(Rectangle())
        .onTapGesture { model.play(result) }
    }

    var bottomBar: some View {
        HStack {
            Text(model.status)
                .font(.system(size: 7 * zoom, design: .monospaced))
                .foregroundColor(theme.primary.opacity(0.6))
                .lineLimit(1)
            Spacer()
            Text("↵ PLAY")
                .font(.system(size: 7 * zoom, design: .monospaced))
                .foregroundColor(theme.secondary.opacity(0.5))
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 4 * zoom)
        .background(theme.bottomBg)
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { isShowing = false }
    }
}

// MARK: - Winamp Skin View

struct WinampView: View {
    @Environment(\.uiScale) private var zoom
    @ObservedObject var buttonStore: ButtonStore
    @Binding var currentTrack: String
    @Binding var currentArtist: String
    @Binding var currentPlaylist: String
    @Binding var isPlaying: Bool
    @Binding var shuffleEnabled: Bool
    @Binding var albumArt: NSImage?
    @Binding var showBanner: Bool
    @Binding var bannerMessage: String
    @Binding var bannerType: BannerType
    @Binding var isLoading: [String: Bool]
    @Binding var showSettings: Bool
    @Binding var playlists: [String]
    @Binding var volume: Double
    @Binding var playerPosition: Double
    @Binding var trackDuration: Double
    @Binding var showExpandedArt: Bool
    @Binding var showPlaylist: Bool
    var refreshTrackInfo: () -> Void
    var resizeWindow: () -> Void
    var performAction: (String, () -> Void) -> Void
    var showResult: (Bool, String) -> Void

    // Winamp green: #00FF00, amber: #FFAA00
    private let winGreen = Color(red: 0, green: 1, blue: 0)
    private let winAmber = Color(red: 1, green: 0.67, blue: 0)
    private let winDarkBg = Color(red: 0.1, green: 0.1, blue: 0.12)
    private let winMidBg = Color(red: 0.15, green: 0.15, blue: 0.17)
    private let winBorder = Color(red: 0.25, green: 0.25, blue: 0.3)
    private let winHighlight = Color(red: 0.2, green: 0.2, blue: 0.25)

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            titleBar

            // Main display area
            displayArea

            // Fake EQ visualizer bars
            eqBars

            // Transport controls
            transportControls

            // Playlist action buttons (styled as winamp buttons)
            actionButtons

            // Status bar
            statusBar
        }
        .frame(width: 300 * zoom)
        .background(winDarkBg)
        .border(winBorder, width: 1 * zoom)
        .clipShape(RoundedRectangle(cornerRadius: 4 * zoom))
        // Shadow lives on a static backing shape, not the content, so redraws
        // inside the player don't force the whole view through a shadow pass.
        .background(
            RoundedRectangle(cornerRadius: 4 * zoom)
                .fill(winDarkBg)
                .shadow(color: .black.opacity(0.5), radius: 10 * zoom, x: 0, y: 4 * zoom)
        )
    }

    var titleBar: some View {
        HStack(spacing: 0) {
            // Winamp logo area — also serves as drag handle
            HStack(spacing: 4 * zoom) {
                Image("WinampLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 14 * zoom)
                Text("ZENAMP")
                    .font(.system(size: 9 * zoom, weight: .bold, design: .monospaced))
                    .foregroundColor(winGreen)
                Text("v1.0")
                    .font(.system(size: 7 * zoom, design: .monospaced))
                    .foregroundColor(winGreen.opacity(0.5))
                Spacer()
            }
            
            HStack(spacing: 6 * zoom) {
                AudioOutputMenuButton(size: 8 * zoom, color: NSColor(winGreen.opacity(0.6)))
                    .frame(width: 20 * zoom, height: 20 * zoom)
                AppKitButton(
                    icon: AppState.shared.zoomLevel == 1.0 ? "plus.magnifyingglass" : (AppState.shared.zoomLevel == 1.5 ? "1.magnifyingglass" : "minus.magnifyingglass"),
                    size: 8 * zoom,
                    color: NSColor(winGreen.opacity(0.6)),
                    action: { AppState.shared.cycleZoom(); resizeWindow() }
                )
                .frame(width: 20 * zoom, height: 20 * zoom)
                AppKitButton(
                    icon: AppState.shared.visualizerMode.icon,
                    size: 8 * zoom,
                    color: NSColor(winGreen.opacity(0.6)),
                    action: { AppState.shared.cycleVisualizer() }
                )
                .frame(width: 20 * zoom, height: 20 * zoom)
                AppKitButton(
                    icon: "gearshape.fill",
                    size: 8 * zoom,
                    color: NSColor(winGreen.opacity(0.6)),
                    action: { [self] in withAnimation(.easeInOut(duration: 0.2)) { showSettings = true } }
                )
                .frame(width: 20 * zoom, height: 20 * zoom)
            }
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 5 * zoom)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.12, green: 0.12, blue: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    var displayArea: some View {
        VStack(spacing: 6 * zoom) {
            // Album art + track info side by side
            HStack(spacing: 10 * zoom) {
                // Small album art — click to expand
                ZStack {
                    RoundedRectangle(cornerRadius: 2 * zoom)
                        .fill(Color.black)
                        .frame(width: 64 * zoom, height: 64 * zoom)

                    if let art = albumArt {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 62 * zoom, height: 62 * zoom)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 1 * zoom))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 20 * zoom))
                            .foregroundColor(winGreen.opacity(0.3))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 2 * zoom)
                        .stroke(winGreen.opacity(0.3), lineWidth: 1 * zoom)
                )

                // Track info
                VStack(alignment: .leading, spacing: 4 * zoom) {
                    // Scrolling track name
                    Text(currentTrack.isEmpty ? "- NO TRACK -" : currentTrack.uppercased())
                        .font(.system(size: 12 * zoom, weight: .bold, design: .monospaced))
                        .foregroundColor(winGreen)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(currentArtist.isEmpty ? "" : currentArtist.uppercased())
                        .font(.system(size: 9 * zoom, design: .monospaced))
                        .foregroundColor(winAmber)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Playlist indicator
                    HStack(spacing: 4 * zoom) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 7 * zoom))
                            .foregroundColor(winGreen.opacity(0.5))
                        Menu {
                            ForEach(playlists, id: \.self) { name in
                                Button(action: {
                                    MusicController.playPlaylist(name) { success, message in
                                        if success {
                                            currentPlaylist = name
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                refreshTrackInfo()
                                            }
                                        }
                                        showResult(success, message)
                                    }
                                }) {
                                    HStack {
                                        Text(name)
                                        if name == currentPlaylist {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(currentPlaylist.isEmpty ? "NO PLAYLIST" : currentPlaylist.uppercased())
                                .font(.system(size: 8 * zoom, design: .monospaced))
                                .foregroundColor(winGreen.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .menuStyle(BorderlessButtonMenuStyle())
                    }

                    // Status
                    HStack(spacing: 6 * zoom) {
                        Circle()
                            .fill(isPlaying ? winGreen : Color.red)
                            .frame(width: 5 * zoom, height: 5 * zoom)
                        Text(isPlaying ? "PLAYING" : "PAUSED")
                            .font(.system(size: 8 * zoom, weight: .medium, design: .monospaced))
                            .foregroundColor(isPlaying ? winGreen.opacity(0.7) : Color.red.opacity(0.7))

                        Spacer()

                        Text(shuffleEnabled ? "SHUF" : "")
                            .font(.system(size: 7 * zoom, weight: .bold, design: .monospaced))
                            .foregroundColor(winAmber.opacity(0.6))
                    }
                }
            }
        }
        .padding(10 * zoom)
        .background(
            RoundedRectangle(cornerRadius: 3 * zoom)
                .fill(Color.black.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3 * zoom)
                .stroke(winGreen.opacity(0.15), lineWidth: 1 * zoom)
        )
        .padding(.horizontal, 6 * zoom)
        .padding(.top, 4 * zoom)
    }

    var eqBars: some View {
        VStack(spacing: 4 * zoom) {
            if let style = AppState.shared.visualizerMode.style {
                AudioWaveformView(isPlaying: isPlaying && AppState.shared.isWindowVisible, style: style)
                    .frame(height: 18 * zoom)
            }

            ProgressBarView(position: playerPosition, duration: trackDuration, accentColor: winGreen)

            VolumeSliderView(volume: $volume, accentColor: winGreen)
                .frame(height: 12 * zoom)
        }
        .padding(.horizontal, 10 * zoom)
        .padding(.vertical, 6 * zoom)
        .background(Color.black.opacity(0.4))
        .padding(.horizontal, 6 * zoom)
        .padding(.top, 4 * zoom)
    }

    var transportControls: some View {
        HStack(spacing: 0) {
            // Previous
            winampButton(icon: "backward.fill", label: "PREV") {
                Transport.previous { refreshTrackInfo() }
            }

            // Play/Pause
            winampButton(icon: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "PAUSE" : "PLAY", highlight: true) {
                Transport.playPause { refreshTrackInfo() }
            }

            // Next
            winampButton(icon: "forward.fill", label: "NEXT") {
                Transport.next { refreshTrackInfo() }
            }

            // Stop (rewind to beginning)
            winampButton(icon: "stop.fill", label: "STOP") {
                Transport.playPause { refreshTrackInfo() }
            }

            Spacer()

            // Shuffle
            winampButton(icon: "shuffle", label: "SHUF", active: shuffleEnabled) {
                MusicController.toggleShuffle { enabled in
                    shuffleEnabled = enabled
                }
            }

            // Playlist toggle
            winampButton(icon: "list.bullet", label: "PL", active: showPlaylist) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showPlaylist.toggle()
                }
                resizeWindow()
            }

            // Apple Music search toggle
            // Opens the search, or refocuses it if open; X or Esc closes it.
            winampButton(icon: "magnifyingglass", label: "FIND", active: AppState.shared.showSearch) {
                if AppState.shared.showSearch {
                    SearchModel.shared.focusRequest += 1
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        AppState.shared.showSearch = true
                    }
                    resizeWindow()
                }
            }
        }
        .padding(.horizontal, 6 * zoom)
        .padding(.vertical, 4 * zoom)
    }

    func winampButton(icon: String, label: String, highlight: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2 * zoom) {
                Image(systemName: icon)
                    .font(.system(size: 11 * zoom, weight: .bold))
                Text(label)
                    .font(.system(size: 6 * zoom, weight: .bold, design: .monospaced))
            }
            .foregroundColor(active ? winAmber : (highlight ? winGreen : winGreen.opacity(0.7)))
            .frame(width: 36 * zoom, height: 32 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 3 * zoom)
                    .fill(winMidBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3 * zoom)
                            .stroke(active ? winAmber.opacity(0.5) : winBorder, lineWidth: 1 * zoom)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 2 * zoom)
    }

    var actionButtons: some View {
        VStack(spacing: 3 * zoom) {
            ForEach(buttonStore.buttons) { config in
                Button(action: {
                    if config.isFavorite {
                        performAction(config.id) {
                            MusicController.favoriteCurrentTrack { success, message in
                                showResult(success, message)
                            }
                        }
                    } else {
                        performAction(config.id) {
                            MusicController.addCurrentTrackToPlaylist(config.playlist) { success, message in
                                showResult(success, message)
                            }
                        }
                    }
                }) {
                    HStack(spacing: 8 * zoom) {
                        Image(systemName: config.icon)
                            .font(.system(size: 10 * zoom, weight: .bold))
                            .foregroundColor(winGreen)
                            .frame(width: 16 * zoom)

                        Text(config.title.uppercased())
                            .font(.system(size: 9 * zoom, weight: .bold, design: .monospaced))
                            .foregroundColor(winGreen.opacity(0.9))

                        Spacer()

                        if isLoading[config.id] == true {
                            ProgressView()
                                .scaleEffect(0.4 * zoom)
                        } else {
                            Text(config.isFavorite ? "FAV" : "ADD")
                                .font(.system(size: 7 * zoom, weight: .bold, design: .monospaced))
                                .foregroundColor(winAmber.opacity(0.6))
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 7 * zoom))
                            .foregroundColor(winGreen.opacity(0.3))
                    }
                    .padding(.horizontal, 10 * zoom)
                    .padding(.vertical, 6 * zoom)
                    .background(
                        RoundedRectangle(cornerRadius: 2 * zoom)
                            .fill(winMidBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2 * zoom)
                                    .stroke(winGreen.opacity(0.1), lineWidth: 1 * zoom)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 6 * zoom)
        .padding(.vertical, 4 * zoom)
    }

    var statusBar: some View {
        HStack(spacing: 4 * zoom) {
            if showBanner {
                Image(systemName: bannerType.icon)
                    .font(.system(size: 7 * zoom))
                    .foregroundColor(bannerType == .success ? winGreen : (bannerType == .error ? Color.red : winAmber))
                Text(bannerMessage.uppercased())
                    .font(.system(size: 7 * zoom, design: .monospaced))
                    .foregroundColor(bannerType == .success ? winGreen : (bannerType == .error ? Color.red : winAmber))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("READY")
                    .font(.system(size: 7 * zoom, design: .monospaced))
                    .foregroundColor(winGreen.opacity(0.4))
            }
            Spacer()
            Text("♫")
                .font(.system(size: 8 * zoom))
                .foregroundColor(winGreen.opacity(0.3))
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 4 * zoom)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - Visual Effect (Translucent Background)

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - App

enum VisualizerMode: String, CaseIterable, Codable {
    case off = "Off"
    case bars = "Bars"
    case mirror = "Mirror"
    case glow = "Glow"

    var icon: String {
        switch self {
        case .off: return "waveform.slash"
        case .bars: return "chart.bar.fill"
        case .mirror: return "waveform"
        case .glow: return "waveform.path"
        }
    }

    var style: AudioWaveformView.WaveformStyle? {
        switch self {
        case .off: return nil
        case .bars: return .bars
        case .mirror: return .mirror
        case .glow: return .glow
        }
    }

    func next() -> VisualizerMode {
        let all = VisualizerMode.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

struct AppPrefs: Codable {
    var visualizerMode: String = VisualizerMode.bars.rawValue
    var showExpandedArt: Bool = false
    var showPlaylist: Bool = false
    var zoomLevel: Double = 1.5
}

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var visualizerMode: VisualizerMode = .bars { didSet { savePrefs() } }
    @Published var showExpandedArt: Bool = false { didSet { savePrefs() } }
    @Published var showPlaylist: Bool = false {
        didSet {
            savePrefs()
            if showPlaylist { showSearch = false }
        }
    }
    /// The search panel and playlist panel replace each other below the player.
    @Published var showSearch: Bool = false {
        didSet { if showSearch { showPlaylist = false } }
    }
    @Published var zoomLevel: Double = 1.5 { didSet { savePrefs() } }
    /// False when the window is fully covered, hidden, or on another Space.
    @Published var isWindowVisible: Bool = true

    private var suppressSave = true

    private static var prefsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".zenamp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prefs.json")
    }

    init() {
        if let data = try? Data(contentsOf: AppState.prefsURL),
           let prefs = try? JSONDecoder().decode(AppPrefs.self, from: data) {
            self.visualizerMode = VisualizerMode(rawValue: prefs.visualizerMode) ?? .bars
            self.showExpandedArt = prefs.showExpandedArt
            self.showPlaylist = prefs.showPlaylist
            self.zoomLevel = prefs.zoomLevel
        }
        suppressSave = false
    }

    func savePrefs() {
        guard !suppressSave else { return }
        let prefs = AppPrefs(
            visualizerMode: visualizerMode.rawValue,
            showExpandedArt: showExpandedArt,
            showPlaylist: showPlaylist,
            zoomLevel: zoomLevel
        )
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: AppState.prefsURL)
        }
    }

    func cycleVisualizer() {
        visualizerMode = visualizerMode.next()
    }

    func cycleZoom() {
        let levels = [1.0, 1.5, 2.0]
        if let idx = levels.firstIndex(of: zoomLevel) {
            zoomLevel = levels[(idx + 1) % levels.count]
        } else {
            zoomLevel = 1.0
        }
    }
}

enum AppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }
}

@main
struct ZenAmpLauncher {
    static func main() {
        AppMain.main()
    }
}

class BorderlessKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    var mainWindow: NSWindow?

    private let windowXKey = "windowPositionX"
    private let windowYKey = "windowPositionY"
    private var dragMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = BorderlessKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 520),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ZenAMP"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        // The player draws its own drop shadow; the system one would trace an
        // outline around that shadow's faded edge on this transparent window.
        window.hasShadow = false
        window.isRestorable = false
        window.restorationClass = nil
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ContentView())

        // Restore saved position, but only if it still lands on a connected display.
        // Display arrangements change, and a borderless window stranded off-screen
        // has no title bar or Window menu the user could recover it with.
        if UserDefaults.standard.object(forKey: windowXKey) != nil {
            let x = UserDefaults.standard.double(forKey: windowXKey)
            let y = UserDefaults.standard.double(forKey: windowYKey)
            var restored = window.frame
            restored.origin = NSPoint(x: x, y: y)
            if AppDelegate.isGrabbable(restored) {
                window.setFrameOrigin(restored.origin)
            } else {
                window.center()
            }
        } else {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        mainWindow = window

        installTitleBarDragMonitor()

        // Unplugging a display can strand the window just as badly as a stale
        // saved position — pull it back into view when the arrangement changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Makes the title bar drag the window.
    ///
    /// `isMovableByWindowBackground` never fires because NSHostingView consumes
    /// mouse-down across the whole SwiftUI surface. A local event monitor
    /// sidesteps that — it reads raw window coordinates before the event is
    /// ever dispatched into the view hierarchy.
    private func installTitleBarDragMonitor() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = self.mainWindow,
                  event.window === window,
                  self.isInTitleBarDragZone(event, in: window)
            else { return event }

            window.performDrag(with: event)
            return nil  // swallow it; the drag loop owns this event now
        }
    }

    /// The title bar strip, minus the right-hand cluster of control buttons.
    /// Measured in window points, which already include the zoom scale.
    private func isInTitleBarDragZone(_ event: NSEvent, in window: NSWindow) -> Bool {
        let zoom = CGFloat(AppState.shared.zoomLevel)
        let titleBarHeight: CGFloat = 30 * zoom
        let controlClusterWidth: CGFloat = 115 * zoom

        let point = event.locationInWindow          // bottom-left origin
        let distanceFromTop = window.frame.height - point.y

        return distanceFromTop >= 0
            && distanceFromTop <= titleBarHeight
            && point.x <= window.frame.width - controlClusterWidth
    }

    @objc private func screenParametersChanged() {
        guard let window = mainWindow, !AppDelegate.isGrabbable(window.frame) else { return }
        window.center()
        saveWindowPosition()
    }

    /// True when enough of the window's drag handle sits on a connected screen
    /// for the user to actually grab it.
    private static func isGrabbable(_ frame: NSRect) -> Bool {
        let handleHeight: CGFloat = 30
        let handle = NSRect(
            x: frame.minX,
            y: frame.maxY - handleHeight,
            width: frame.width,
            height: handleHeight
        )
        return NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(handle)
            return overlap.width >= 100 && overlap.height >= 20
        }
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowPosition()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = mainWindow else { return }
        let visible = window.occlusionState.contains(.visible)
        if AppState.shared.isWindowVisible != visible {
            AppState.shared.isWindowVisible = visible
        }
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowPosition()
        NSApp.terminate(nil)
    }

    private func saveWindowPosition() {
        guard let frame = mainWindow?.frame else { return }
        UserDefaults.standard.set(Double(frame.origin.x), forKey: windowXKey)
        UserDefaults.standard.set(Double(frame.origin.y), forKey: windowYKey)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return true
    }
}

