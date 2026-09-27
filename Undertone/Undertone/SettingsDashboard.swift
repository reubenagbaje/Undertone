import SwiftUI
import AppKit

struct SettingsDashboard: View {
    @ObservedObject var state: IslandState
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var audio: AudioCapture
    @ObservedObject var lockPlayer: LockScreenPlayerController
    @AppStorage("lockPlayerLiquidGlass") private var lockPlayerLiquidGlass = false
    @AppStorage("enableLockScreenPlayer") private var enableLockScreenPlayer = false
    @AppStorage("lockPlayerAmbientGlow") private var ambientGlow = true
    @AppStorage("lockPlayerSyncedLyrics") private var syncedLyrics = false
    @AppStorage("lockPlayerUnlockAnimation") private var unlockAnimation = true
    @StateObject private var login = LoginLaunch()
    @AppStorage("enablePlayerShortcuts") private var shortcuts = true
    @AppStorage("artworkAccent") private var artworkAccent = false
    @State var selectedTab = 0
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                general.tag(0).tabItem { Label("General", systemImage: "gearshape") }
                modules.tag(1).tabItem { Label("Modules", systemImage: "square.grid.2x2") }
                appearance.tag(2).tabItem { Label("Appearance", systemImage: "paintpalette") }
            }
            Divider()
            HStack {
                Text("Made by Reuben Agbaje").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Undertone") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 620, height: 650)
    }
    private var general: some View {
        Form {
            Section("Startup & shortcuts") {
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: login.set))
                if let message = login.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Toggle("Global player shortcuts", isOn: $shortcuts)
                    .onChange(of: shortcuts) { _ in NotificationCenter.default.post(name: .init("UndertoneShortcutPreferenceChanged"), object: nil) }
                Text("⌘⌥U Player · ⌘⌥Space Play/Pause · ⌘⌥←/→ Previous/Next · ⌘⌥L Like · ⌘⌥K Lock player")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Player") {
                Toggle("Hover haptics", isOn: $state.haptics)
                Toggle("Keep player expanded", isOn: $state.pinned)
                Toggle("Reverse swipe direction", isOn: $state.reverseSwipes)
            }
            Section("Volume indicator") { VolumeHUDSettings() }
            Section("Sleep timer") { SleepTimerSettings(timer: spotify.sleepTimer) { spotify.pause() } }
            Section("Updates") { UpdateSettings() }
            Section("Spotify") {
                LabeledContent("Connection", value: spotify.connected ? "Connected automatically" : "Waiting for Spotify")
                Text("Undertone connects when Spotify opens and retries temporary errors. The first connection requires Automation permission.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Button("Open Spotify") { spotify.openSpotify() }; Button("Retry connection") { spotify.connect() } }
                if let error = spotify.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                SpotifyLibrarySettings(library: spotify.library)
            }
            Section("Audio") {
                Text(audio.message).font(.callout)
                HStack {
                    Button(audio.running ? "Stop Spotify audio" : "Enable Spotify audio") {
                        Task { if audio.running { await audio.stop() } else { await audio.start() } }
                    }
                    Button("Restart audio") { Task { await audio.restart() } }
                }.disabled(audio.busy)
                Text("Audio stays on this Mac. Other apps’ audio is excluded.").font(.caption).foregroundStyle(.secondary)
                Button("Privacy settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
            }
        }.formStyle(.grouped)
    }
    private var modules: some View {
        Form {
            Section("Now Playing") {
                Toggle("Lock Screen Media Player", isOn: $enableLockScreenPlayer)
                Text("Shows a media overlay after locking an already signed-in Mac. Tap artwork to expand or collapse it. Move the pointer down to the password area to collapse full-screen artwork. The player never takes keyboard focus. Visibility remains macOS-version dependent.")
                    .font(.caption).foregroundStyle(.secondary)
                Group {
                    Toggle("Liquid Glass player", isOn: $lockPlayerLiquidGlass)
                    Toggle("Dynamic Artwork Ambient Glow", isOn: $ambientGlow)
                    Toggle("Synced Moving Lyrics", isOn: $syncedLyrics)
                    Toggle("Smooth Unlocking Shrink Animation", isOn: $unlockAnimation)
                }.disabled(!enableLockScreenPlayer)
                Button("Preview Now Playing") { lockPlayer.preview() }
                Text("Tap the thumbnail to fill the preview with artwork; tap the artwork or collapse button to return. This preview does not lock your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(lockPlayer.status).font(.caption).foregroundStyle(.secondary)
            }
            Section("Lyrics") {
                LyricsImportSettings(store: lockPlayer.lyrics, spotify: spotify)
            }
        }.formStyle(.grouped)
    }
    private var appearance: some View {
        Form {
            Section("Notch") {
                Picker("Display style", selection: $state.dynamicIsland) {
                    Text("Notch").tag(false)
                    Text("Dynamic Island").tag(true)
                }.pickerStyle(.segmented)
                if state.dynamicIsland {
                    LabeledContent("Distance below menu bar", value: "\(Int(state.islandGap)) pt")
                    Slider(value: $state.islandGap, in: 8...80, step: 1).accessibilityLabel("Dynamic Island vertical position")
                }
                Toggle("Always show notch or island", isOn: $state.alwaysShowNotch)
                Text("Keep a black notch visible while idle, including on Macs without a camera notch.").font(.caption).foregroundStyle(.secondary)
                Toggle("Artwork colour accents", isOn: $artworkAccent)
                Toggle("Thin white outline", isOn: $state.whiteOutline)
                Toggle("Black to Liquid Glass", isOn: $state.glassAppearance)
                Text("Black around the camera, fading into glass in the expanded player.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Idle top-corner curve", value: "\(Int(state.idleCornerCurve))")
                Slider(value: $state.idleCornerCurve, in: 0...16, step: 1).accessibilityLabel("Idle top-corner curve")
                HStack { Text("Straight"); Spacer(); Text("More curved") }.font(.caption).foregroundStyle(.secondary)
                Button("Reset curve") { state.idleCornerCurve = 6 }
            }
            Section("Accessibility") {
                Text("Undertone follows macOS Reduce Motion and Reduce Transparency. Haptics require a compatible trackpad.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct LyricsImportSettings: View {
    @ObservedObject var store: LyricsStore
    @ObservedObject var spotify: SpotifyController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import a timed .lrc file you have permission to use. Spotify does not supply lyrics through Undertone’s API connection.").font(.caption).foregroundStyle(.secondary)
            Button("Import lyrics for current song…") { store.importCurrentTrack(spotify.trackID) }.disabled(!spotify.connected || spotify.trackID.isEmpty)
            Text(store.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// Use SwiftUI's native Settings action on modern macOS, preserving the native
// scene's single-window lifecycle and standard Command-comma menu command.
struct SettingsRequestHandler: View {
    @ObservedObject var state: IslandState
    var body: some View {
        if #available(macOS 14.0, *) { ModernSettingsRequestHandler(state: state) }
        else {
            Color.clear.frame(width: 0, height: 0).onChange(of: state.settingsOpen) { requested in
                guard requested else { return }
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                state.settingsOpen = false
            }
        }
    }
}
@available(macOS 14.0, *)
private struct ModernSettingsRequestHandler: View {
    @ObservedObject var state: IslandState
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onChange(of: state.settingsOpen) { requested in
            guard requested else { return }
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            state.settingsOpen = false
        }
    }
}
