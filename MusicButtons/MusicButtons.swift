import SwiftUI
import AppKit
import CoreAudio

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
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name) == noErr else { return nil }
        return name as String
    }
}

// MARK: - AppKit Button (works with isMovableByWindowBackground)

struct AppKitButton: NSViewRepresentable {
    let icon: String
    let size: CGFloat
    let color: NSColor
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        button.contentTintColor = color
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        button.contentTintColor = color
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    class Coordinator: NSObject {
        var action: () -> Void
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
        button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Audio Output")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        button.contentTintColor = color
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.contentTintColor = color
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
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

    static func runAppleScript(_ script: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = pipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        completion(true, output)
                    } else {
                        completion(false, errorOutput.isEmpty ? "Unknown error" : errorOutput)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
    
    static func getCurrentTrackInfo(completion: @escaping (String?, String?, String?, Bool) -> Void) {
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
                    set currentSource to container of current track
                    if class of currentSource is user playlist then
                        set playlistName to name of currentSource
                    end if
                end try
                return trackName & " | " & trackArtist & " | " & playlistName & " | " & isPlaying
            else
                return "NOTHING_PLAYING"
            end if
        end tell
        """
        runAppleScript(script) { success, result in
            if success && result != "NOTHING_PLAYING" {
                let parts = result.components(separatedBy: " | ")
                let name = parts.first
                let artist = parts.count > 1 ? parts[1] : nil
                let playlist = parts.count > 2 ? parts[2] : nil
                let playing = parts.last == "true"
                completion(name, artist, playlist, playing)
            } else {
                completion(nil, nil, nil, false)
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
                    set tmpPath to "/tmp/musicbuttons_art.jpg"
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
                let image = NSImage(contentsOfFile: result)
                completion(image)
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

    static func fetchCurrentPlaylistTracks(completion: @escaping ([(name: String, artist: String, duration: String, isPlaying: Bool)]) -> Void) {
        let script = """
        tell application "Music"
            set currentName to ""
            set currentArtist to ""
            try
                if player state is playing or player state is paused then
                    set currentName to name of current track
                    set currentArtist to artist of current track
                end if
            end try
            try
                set src to container of current track
                set allNames to name of tracks of src
                set allArtists to artist of tracks of src
                set allDurs to duration of tracks of src
                set maxTracks to count of allNames
                if maxTracks > 200 then set maxTracks to 200
                set output to {}
                repeat with i from 1 to maxTracks
                    set tName to item i of allNames
                    set tArtist to item i of allArtists
                    set tDur to item i of allDurs
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
                    set end of output to tName & ":::" & tArtist & ":::" & durStr & ":::" & isNowPlaying
                end repeat
                set AppleScript's text item delimiters to "|||"
                return output as text
            end try
            return ""
        end tell
        """
        runAppleScript(script) { success, result in
            if success && !result.isEmpty {
                let tracks = result.components(separatedBy: "|||").compactMap { line -> (name: String, artist: String, duration: String, isPlaying: Bool)? in
                    let parts = line.components(separatedBy: ":::")
                    guard parts.count >= 4 else { return nil }
                    return (name: parts[0], artist: parts[1], duration: parts[2], isPlaying: parts[3] == "1")
                }
                completion(tracks)
            } else {
                completion([])
            }
        }
    }

    static func playTrackAtIndex(_ index: Int, completion: @escaping (Bool) -> Void) {
        let script = """
        tell application "Music"
            try
                set src to view of front window
                play track \(index + 1) of src
                return "ok"
            end try
            return "error"
        end tell
        """
        runAppleScript(script) { success, _ in
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

    static func setVolume(_ volume: Double) {
        let v = Int(max(0, min(100, volume)))
        let script = "tell application \"Music\" to set sound volume to \(v)"
        runAppleScript(script) { _, _ in }
    }

    static func getPlayerPosition(completion: @escaping (Double, Double) -> Void) {
        let script = """
        tell application "Music"
            if player state is playing or player state is paused then
                set pos to player position
                set dur to duration of current track
                return (pos as text) & "|" & (dur as text)
            else
                return "0|0"
            end if
        end tell
        """
        runAppleScript(script) { success, result in
            let parts = result.components(separatedBy: "|")
            let pos = Double(parts.first ?? "0") ?? 0
            let dur = Double(parts.last ?? "0") ?? 0
            completion(pos, dur)
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
        let dir = home.appendingPathComponent(".musicbuttons")
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
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)

                Spacer()

                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // Invisible spacer to balance the header
                Button(action: {}) { Text("Back").font(.system(size: 12)) }
                    .hidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    ForEach($editingButtons) { $button in
                        ButtonSettingsRow(config: $button, playlists: playlists)
                    }

                    // Skin picker
                    // Visualizer picker
                    HStack {
                        Image(systemName: AppState.shared.visualizerMode.icon)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Visualizer")
                            .font(.system(size: 12))
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
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                    )
                }
                .padding(16)
            }

            Divider()

            // Footer buttons
            HStack(spacing: 12) {
                Button("Reset") {
                    editingButtons = ButtonConfig.defaults
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
                .font(.system(size: 11))

                Spacer()

                Button("Save") {
                    store.buttons = editingButtons
                    store.save()
                    withAnimation(.easeInOut(duration: 0.2)) { isShowing = false }
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.blue)
                .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        .onAppear {
            editingButtons = store.buttons
            MusicController.fetchPlaylists { names in
                playlists = names
            }
        }
    }
}

struct ButtonSettingsRow: View {
    @Binding var config: ButtonConfig
    var playlists: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Preview
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(config.color.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: config.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(config.color)
                }

                Text(config.title.isEmpty ? "Untitled" : config.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(config.title.isEmpty ? .secondary : .primary)

                Spacer()
            }

            // Title field
            HStack {
                Text("Label")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
                TextField("Button name", text: $config.title)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 11))
            }

            // Action type
            HStack {
                Text("Action")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
                Picker("", selection: $config.isFavorite) {
                    Text("♥ Favorite Track").tag(true)
                    Text("Add to Playlist").tag(false)
                }
                .pickerStyle(MenuPickerStyle())
                .font(.system(size: 11))
                .labelsHidden()
            }

            // Playlist picker (only for non-favorite)
            if !config.isFavorite {
                HStack {
                    Text("Playlist")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    if playlists.isEmpty {
                        TextField("Playlist name", text: $config.playlist)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 11))
                    } else {
                        Picker("", selection: $config.playlist) {
                            Text("Select playlist...").tag("")
                            ForEach(playlists, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .font(.system(size: 11))
                        .labelsHidden()
                    }
                }
            }

            // Color picker
            HStack {
                Text("Color")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
                HStack(spacing: 6) {
                    ForEach(ButtonConfig.availableColors, id: \.self) { colorName in
                        Circle()
                            .fill(colorFor(colorName))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: config.colorName == colorName ? 2 : 0)
                            )
                            .shadow(color: config.colorName == colorName ? colorFor(colorName).opacity(0.5) : .clear, radius: 3)
                            .onTapGesture { config.colorName = colorName }
                    }
                }
            }

            // Icon picker
            HStack(alignment: .top) {
                Text("Icon")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .padding(.top, 2)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 4), count: 8), spacing: 4) {
                    ForEach(ButtonConfig.availableIcons, id: \.self) { iconName in
                        Image(systemName: iconName)
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(config.icon == iconName ? config.color.opacity(0.2) : Color.clear)
                            )
                            .foregroundColor(config.icon == iconName ? config.color : .secondary)
                            .onTapGesture { config.icon = iconName }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
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
    @StateObject private var waveformEngine = WaveformEngine()
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
    @State private var previousArt: NSImage? = nil
    @State private var artTransition: Bool = false
    @State private var lastArtTrack: String = ""
    @State private var volume: Double = 50
    @State private var playerPosition: Double = 0
    @State private var trackDuration: Double = 0

    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    let positionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                SettingsView(store: buttonStore, isShowing: $showSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                WinampView(
                    buttonStore: buttonStore,
                    waveformEngine: waveformEngine,
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
                .frame(height: 250)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        } // end VStack
        .animation(.easeInOut(duration: 0.25), value: appState.showPlaylist)
        .onAppear {
            refreshTrackInfo()
            MusicController.fetchPlaylists { names in playlists = names }
            MusicController.getShuffleState { enabled in shuffleEnabled = enabled }
            MusicController.getVolume { v in volume = v }
        }
        .onReceive(timer) { _ in refreshTrackInfo() }
        .onReceive(positionTimer) { _ in
            MusicController.getPlayerPosition { pos, dur in
                playerPosition = pos
                trackDuration = dur
            }
        }
    }


    func resizeWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = AppDelegate.shared?.mainWindow {
                let baseWidth: CGFloat = 300
                let artHeight: CGFloat = self.appState.showExpandedArt ? 300 : 0
                let baseHeight: CGFloat = 520
                let playlistHeight: CGFloat = self.appState.showPlaylist ? 250 : 0
                let targetWidth = baseWidth
                let targetHeight = baseHeight + artHeight + playlistHeight

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
        MusicController.getCurrentTrackInfo { name, artist, playlist, playing in
            withAnimation(.easeInOut(duration: 0.2)) {
                currentTrack = name ?? ""
                currentArtist = artist ?? ""
                currentPlaylist = playlist ?? ""
                isPlaying = playing
            }
            // Only fetch artwork when track changes — crossfade
            let trackKey = (name ?? "") + (artist ?? "")
            if trackKey != lastArtTrack {
                lastArtTrack = trackKey
                if name != nil {
                    MusicController.fetchArtwork { image in
                        previousArt = albumArt
                        artTransition = true
                        withAnimation(.easeInOut(duration: 0.6)) {
                            albumArt = image
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            previousArt = nil
                            artTransition = false
                        }
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        albumArt = nil
                    }
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
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(color)
                    }
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(color.opacity(isHovered ? 1.0 : 0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPressed ? color.opacity(0.1) : (isHovered ? color.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? color.opacity(0.3) : Color.clear, lineWidth: 1)
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

class WaveformEngine: ObservableObject {
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 32)
    private var displayLink: CVDisplayLink?
    private var phase: Double = 0
    private var isAnimating = false

    func start() {
        guard !isAnimating else { return }
        isAnimating = true
        // Use a timer at 30fps for the waveform
        Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isAnimating else {
                timer.invalidate()
                return
            }
            self.phase += 0.15
            var newLevels = [CGFloat]()
            for i in 0..<32 {
                let x = Double(i) / 32.0
                // Combine multiple sine waves for organic look
                let wave1 = sin(x * 4.0 + self.phase) * 0.3
                let wave2 = sin(x * 7.0 + self.phase * 1.3) * 0.2
                let wave3 = sin(x * 13.0 + self.phase * 0.7) * 0.15
                let wave4 = cos(x * 3.0 + self.phase * 1.8) * 0.1
                let noise = Double.random(in: -0.1...0.1)
                let combined = (wave1 + wave2 + wave3 + wave4 + noise + 0.5)
                newLevels.append(CGFloat(max(0.05, min(1.0, combined))))
            }
            DispatchQueue.main.async {
                self.levels = newLevels
            }
        }
    }

    func stop() {
        isAnimating = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.5)) {
                self.levels = Array(repeating: 0.05, count: 32)
            }
        }
    }
}

struct AudioWaveformView: View {
    @ObservedObject var engine: WaveformEngine
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

    var body: some View {
        GeometryReader { geo in
            switch style {
            case .bars:
                barsView(size: geo.size)
            case .mirror:
                mirrorView(size: geo.size)
            case .glow:
                glowView(size: geo.size)
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing { engine.start() } else { engine.stop() }
        }
        .onAppear {
            if isPlaying { engine.start() }
        }
    }

    func barsView(size: CGSize) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<engine.levels.count, id: \.self) { i in
                let level = engine.levels[i]
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: style.colors,
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: size.height * level)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    func mirrorView(size: CGSize) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<engine.levels.count, id: \.self) { i in
                let level = engine.levels[i]
                VStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(
                            LinearGradient(colors: style.colors, startPoint: .bottom, endPoint: .top)
                        )
                        .frame(height: size.height * 0.5 * level)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(
                            LinearGradient(colors: style.colors.map { $0.opacity(0.4) }, startPoint: .top, endPoint: .bottom)
                        )
                        .frame(height: size.height * 0.3 * level)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    func glowView(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let midY = h / 2
            var path = Path()
            for (i, level) in engine.levels.enumerated() {
                let x = w * CGFloat(i) / CGFloat(engine.levels.count)
                let y = midY + (level - 0.5) * h * 0.8
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    let prevX = w * CGFloat(i - 1) / CGFloat(engine.levels.count)
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
}

// MARK: - Volume Slider

// MARK: - Progress Bar

struct ProgressBarView: View {
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
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 4)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor)
                        .frame(width: geo.size.width * progress, height: 4)

                    // Scrubber dot
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: max(0, geo.size.width * progress - 4))
                }
            }
            .frame(height: 8)

            HStack {
                Text(formatTime(position))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("-\(formatTime(max(0, duration - position)))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct VolumeSliderView: View {
    @Binding var volume: Double
    var accentColor: Color = .white

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 9))
                .foregroundColor(accentColor.opacity(0.6))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor.opacity(0.15))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor.opacity(0.6))
                        .frame(width: geo.size.width * volume / 100, height: 4)
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
            .frame(height: 16)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 9))
                .foregroundColor(accentColor.opacity(0.6))
        }
    }
}

// MARK: - Skin Definitions

// MARK: - Playlist Scroller View

struct PlaylistTrack: Identifiable, Equatable {
    let id: Int
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
    @Binding var isShowing: Bool
    @Binding var currentPlaylist: String
    @Binding var currentTrack: String
    @State private var tracks: [PlaylistTrack] = []
    @State private var isLoading = true
    var refreshTrackInfo: () -> Void
    @ObservedObject var appState = AppState.shared

    var theme: PlaylistTheme { .zenamp }

    var body: some View {
        VStack(spacing: 0) {
            plTitleBar
            trackListView
            plBottomBar
        }
        .frame(width: 300)
        .background(theme.bg)
        .border(theme.border, width: 1)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { loadTracks() }
        .onChange(of: currentTrack) { _ in loadTracks() }
    }

    var plTitleBar: some View {
        let titleText = currentPlaylist.isEmpty ? "Playlist" : currentPlaylist
        return HStack {
            Image(systemName: "list.bullet")
                .font(.system(size: 8))
                .foregroundColor(titleBarFg)
            Text(theme.isUppercased ? titleText.uppercased() : titleText)
                .font(.system(size: 9, weight: .bold, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(titleBarFg)
                .lineLimit(1)
            Text("[\(tracks.count) tracks]")
                .font(.system(size: 8, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(titleBarFg.opacity(0.6))
            Spacer()
            Button(action: { loadTracks() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8))
                    .foregroundColor(titleBarFg.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isShowing = false }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(titleBarFg.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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
                        .scaleEffect(0.6)
                    Text(theme.isUppercased ? "LOADING..." : "Loading...")
                        .font(.system(size: 8, design: theme.isMonospaced ? .monospaced : .default))
                        .foregroundColor(theme.primary.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.listBg)
            } else if tracks.isEmpty {
                VStack {
                    Text(theme.isUppercased ? "NO TRACKS" : "No tracks")
                        .font(.system(size: 10, design: theme.isMonospaced ? .monospaced : .default))
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
        return HStack(spacing: 6) {
            Text(String(format: "%02d", track.id + 1))
                .font(.system(size: 8, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(track.isPlaying ? theme.secondary : theme.primary.opacity(0.35))
                .frame(width: 18, alignment: .trailing)

            if track.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 6))
                    .foregroundColor(theme.primary)
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }

            Text(theme.isUppercased ? trackText.uppercased() : trackText)
                .font(.system(size: 9, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(track.isPlaying ? theme.primary : theme.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(track.duration)
                .font(.system(size: 8, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(track.isPlaying ? theme.secondary : theme.primary.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(track.isPlaying ? theme.activeBg : (track.id % 2 == 0 ? theme.rowBg1 : theme.rowBg2))
        .contentShape(Rectangle())
        .onTapGesture {
            MusicController.playTrackAtIndex(track.id) { success in
                if success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        loadTracks()
                        refreshTrackInfo()
                    }
                }
            }
        }
    }

    var plBottomBar: some View {
        HStack {
            if let playing = tracks.first(where: { $0.isPlaying }) {
                let t = theme.isUppercased ? "▶ \(playing.name.uppercased())" : "▶ \(playing.name)"
                Text(t)
                    .font(.system(size: 7, design: theme.isMonospaced ? .monospaced : .default))
                    .foregroundColor(theme.primary.opacity(0.6))
                    .lineLimit(1)
            } else {
                Text(theme.isUppercased ? "STOPPED" : "Stopped")
                    .font(.system(size: 7, design: theme.isMonospaced ? .monospaced : .default))
                    .foregroundColor(theme.primary.opacity(0.4))
            }
            Spacer()
            Text(totalTimeString)
                .font(.system(size: 7, design: theme.isMonospaced ? .monospaced : .default))
                .foregroundColor(theme.secondary.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
            tracks = result.enumerated().map { PlaylistTrack(id: $0.offset, name: $0.element.name, artist: $0.element.artist, duration: $0.element.duration, isPlaying: $0.element.isPlaying) }
            isLoading = false
        }
    }
}

// MARK: - Winamp Skin View

struct WinampView: View {
    @ObservedObject var buttonStore: ButtonStore
    @ObservedObject var waveformEngine: WaveformEngine
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

    @State private var scrollOffset: CGFloat = 0
    @State private var tickerTimer: Timer?

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
        .frame(width: 300)
        .background(winDarkBg)
        .border(winBorder, width: 1)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
    }

    var titleBar: some View {
        HStack(spacing: 0) {
            // Winamp logo area — also serves as drag handle
            HStack(spacing: 4) {
                Image("WinampLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 14)
                Text("ZENAMP")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(winGreen)
                Text("v1.0")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(winGreen.opacity(0.5))
                Spacer()
            }
            
            HStack(spacing: 6) {
                AudioOutputMenuButton(size: 8, color: NSColor(winGreen.opacity(0.6)))
                    .frame(width: 20, height: 20)
                AppKitButton(
                    icon: AppState.shared.visualizerMode.icon,
                    size: 8,
                    color: NSColor(winGreen.opacity(0.6)),
                    action: { AppState.shared.cycleVisualizer() }
                )
                .frame(width: 20, height: 20)
                AppKitButton(
                    icon: "gearshape.fill",
                    size: 8,
                    color: NSColor(winGreen.opacity(0.6)),
                    action: { [self] in withAnimation(.easeInOut(duration: 0.2)) { showSettings = true } }
                )
                .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.12, green: 0.12, blue: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    var displayArea: some View {
        VStack(spacing: 6) {
            // Album art + track info side by side
            HStack(spacing: 10) {
                // Small album art — click to expand
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black)
                        .frame(width: 64, height: 64)

                    if let art = albumArt {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 62, height: 62)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundColor(winGreen.opacity(0.3))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(winGreen.opacity(0.3), lineWidth: 1)
                )

                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    // Scrolling track name
                    Text(currentTrack.isEmpty ? "- NO TRACK -" : currentTrack.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(winGreen)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(currentArtist.isEmpty ? "" : currentArtist.uppercased())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(winAmber)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Playlist indicator
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 7))
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
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(winGreen.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .menuStyle(BorderlessButtonMenuStyle())
                    }

                    // Status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isPlaying ? winGreen : Color.red)
                            .frame(width: 5, height: 5)
                        Text(isPlaying ? "PLAYING" : "PAUSED")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(isPlaying ? winGreen.opacity(0.7) : Color.red.opacity(0.7))

                        Spacer()

                        Text(shuffleEnabled ? "SHUF" : "")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(winAmber.opacity(0.6))
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(winGreen.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    var eqBars: some View {
        VStack(spacing: 4) {
            if let style = AppState.shared.visualizerMode.style {
                AudioWaveformView(engine: waveformEngine, isPlaying: isPlaying, style: style)
                    .frame(height: 18)
            }

            ProgressBarView(position: playerPosition, duration: trackDuration, accentColor: winGreen)

            VolumeSliderView(volume: $volume, accentColor: winGreen)
                .frame(height: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.4))
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    var transportControls: some View {
        HStack(spacing: 0) {
            // Previous
            winampButton(icon: "backward.fill", label: "PREV") {
                MusicController.previousTrack { refreshTrackInfo() }
            }

            // Play/Pause
            winampButton(icon: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "PAUSE" : "PLAY", highlight: true) {
                MusicController.playPause { refreshTrackInfo() }
            }

            // Next
            winampButton(icon: "forward.fill", label: "NEXT") {
                MusicController.nextTrack { refreshTrackInfo() }
            }

            // Stop (rewind to beginning)
            winampButton(icon: "stop.fill", label: "STOP") {
                MusicController.playPause { refreshTrackInfo() }
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
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    func winampButton(icon: String, label: String, highlight: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(label)
                    .font(.system(size: 6, weight: .bold, design: .monospaced))
            }
            .foregroundColor(active ? winAmber : (highlight ? winGreen : winGreen.opacity(0.7)))
            .frame(width: 42, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(winMidBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(active ? winAmber.opacity(0.5) : winBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 2)
    }

    var actionButtons: some View {
        VStack(spacing: 3) {
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
                    HStack(spacing: 8) {
                        Image(systemName: config.icon)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(winGreen)
                            .frame(width: 16)

                        Text(config.title.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(winGreen.opacity(0.9))

                        Spacer()

                        if isLoading[config.id] == true {
                            ProgressView()
                                .scaleEffect(0.4)
                        } else {
                            Text(config.isFavorite ? "FAV" : "ADD")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(winAmber.opacity(0.6))
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 7))
                            .foregroundColor(winGreen.opacity(0.3))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(winMidBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(winGreen.opacity(0.1), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    var statusBar: some View {
        HStack(spacing: 4) {
            if showBanner {
                Image(systemName: bannerType.icon)
                    .font(.system(size: 7))
                    .foregroundColor(bannerType == .success ? winGreen : (bannerType == .error ? Color.red : winAmber))
                Text(bannerMessage.uppercased())
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(bannerType == .success ? winGreen : (bannerType == .error ? Color.red : winAmber))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("READY")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(winGreen.opacity(0.4))
            }
            Spacer()
            Text("♫")
                .font(.system(size: 8))
                .foregroundColor(winGreen.opacity(0.3))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
}

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var visualizerMode: VisualizerMode = .bars { didSet { savePrefs() } }
    @Published var showExpandedArt: Bool = false { didSet { savePrefs() } }
    @Published var showPlaylist: Bool = false { didSet { savePrefs() } }

    private var suppressSave = true

    private static var prefsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".musicbuttons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prefs.json")
    }

    init() {
        if let data = try? Data(contentsOf: AppState.prefsURL),
           let prefs = try? JSONDecoder().decode(AppPrefs.self, from: data) {
            self.visualizerMode = VisualizerMode(rawValue: prefs.visualizerMode) ?? .bars
            self.showExpandedArt = prefs.showExpandedArt
            self.showPlaylist = prefs.showPlaylist
        }
        suppressSave = false
    }

    func savePrefs() {
        guard !suppressSave else { return }
        let prefs = AppPrefs(
            visualizerMode: visualizerMode.rawValue,
            showExpandedArt: showExpandedArt,
            showPlaylist: showPlaylist
        )
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: AppState.prefsURL)
        }
    }

    func cycleVisualizer() {
        visualizerMode = visualizerMode.next()
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
struct MusicButtonsLauncher {
    static func main() {
        AppMain.main()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    var mainWindow: NSWindow?

    private let windowXKey = "windowPositionX"
    private let windowYKey = "windowPositionY"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
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
        window.isRestorable = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ContentView())

        // Restore saved position or center
        if UserDefaults.standard.object(forKey: windowXKey) != nil {
            let x = UserDefaults.standard.double(forKey: windowXKey)
            let y = UserDefaults.standard.double(forKey: windowYKey)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        mainWindow = window
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowPosition()
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

