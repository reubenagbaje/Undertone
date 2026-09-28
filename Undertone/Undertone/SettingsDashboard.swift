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
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 24, weight: .medium))
                        .frame(width: 48, height: 48).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Undertone").font(.system(size: 22, weight: .bold))
                        Text("Make it yours.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    ForEach(0..<3) { tab in
                        Button { selectedTab = tab } label: {
                            Label(["General", "Modules", "Appearance"][tab], systemImage: ["gearshape", "square.grid.2x2", "paintpalette"][tab])
                                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(.white.opacity(selectedTab == tab ? 0.14 : 0.04), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
            Group {
                switch selectedTab { case 1: modules; case 2: appearance; default: general }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Made by Reuben Agbaje").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Undertone") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 620, height: 720)
        .background(Color(white: 0.06)).preferredColorScheme(.dark).tint(.white)
        .buttonStyle(IslandToolButtonStyle())
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
            Section("System indicators") { VolumeHUDSettings() }
            Section("Sleep timer") { SleepTimerSettings(timer: spotify.sleepTimer) { spotify.pause() } }
            Section("Updates") { UpdateSettings() }
            Section("Music player") {
                Picker("Player", selection: $spotify.playerSource) {
                    ForEach(["Spotify", "Apple Music", "Safari", "Chrome"], id: \.self) { Text($0).tag($0) }
                }.onChange(of: spotify.playerSource) { _ in Task { if audio.running { await audio.restart() } } }
                Text("Browser mode controls HTML audio/video in the active tab. Enable JavaScript from Apple Events in that browser’s developer menu. Cross-origin frames and some streaming sites are unavailable. Browser audio capture includes other tabs.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotify account") {
                LabeledContent("Connection", value: spotify.connected ? "Connected automatically" : "Waiting for Spotify")
                Text("Undertone connects when Spotify opens and retries temporary errors. The first connection requires Automation permission.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Button("Open selected player") { spotify.openSpotify() }; Button("Retry connection") { spotify.connect() } }
                if let error = spotify.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                SpotifyLibrarySettings(library: spotify.library)
            }
            Section("Audio") {
                Text(audio.message).font(.callout)
                HStack {
                    Button(audio.running ? "Stop player audio" : "Enable player audio") {
                        Task { if audio.running { await audio.stop() } else { await audio.start() } }
                    }
                    Button("Restart audio") { Task { await audio.restart() } }
                }.disabled(audio.busy)
                Text("Audio stays on this Mac. Capture follows the selected player; browser capture can include all its tabs.").font(.caption).foregroundStyle(.secondary)
                Button("Privacy settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
            }
        }.formStyle(.grouped)
    }
    private var modules: some View {
        Form {
            ModulePreferences(state: state)
            Section("Now Playing") {
                Toggle("Lock Screen Media Player", isOn: $enableLockScreenPlayer)
                Text("Music controls while your Mac is locked. Tap artwork to expand it; move toward the password field to collapse. Availability depends on macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                Group {
                    Toggle("Liquid Glass player", isOn: $lockPlayerLiquidGlass)
                    Toggle("Dynamic Artwork Ambient Glow", isOn: $ambientGlow)
                    Toggle("Synced Moving Lyrics", isOn: $syncedLyrics)
                    Toggle("Smooth Unlocking Shrink Animation", isOn: $unlockAnimation)
                }.disabled(!enableLockScreenPlayer)
                Button("Preview Now Playing") { lockPlayer.preview() }
                Text("Preview without locking your Mac. Tap artwork to expand or collapse.")
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
