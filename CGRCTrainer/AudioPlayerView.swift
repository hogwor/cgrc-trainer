import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: – Play state
enum PlayState { case stopped, playing, paused }

// MARK: – Speech engine
final class SpeechEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()

    @Published var playState: PlayState = .stopped
    @Published var currentParagraph: Int = 0
    @Published var currentTrackID: Int? = nil

    var track: AudioTrack? = nil
    var rate: Float = 0.50

    private var suppressNextDidFinish = false

    // Persistence keys
    private let kTrackID   = "audio_last_track_id"
    private let kParagraph = "audio_last_paragraph"

    override init() {
        super.init()
        synth.delegate = self
        activateAudioSession()
        setupRemoteCommands()
        setupInterruptionHandling()
        restorePosition()
    }

    // MARK: – Persistence
    private func restorePosition() {
        let saved = UserDefaults.standard
        guard let tid = saved.object(forKey: kTrackID) as? Int,
              let t   = AUDIO_LIBRARY.first(where: { $0.id == tid }) else { return }
        track           = t
        currentTrackID  = tid
        currentParagraph = saved.integer(forKey: kParagraph)
        // Restore paused state so UI shows correct position; don't auto-play
        playState = .paused
    }

    private func savePosition() {
        guard let tid = currentTrackID else { return }
        UserDefaults.standard.set(tid,              forKey: kTrackID)
        UserDefaults.standard.set(currentParagraph, forKey: kParagraph)
    }

    // MARK: – Audio session
    private func activateAudioSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? s.setActive(true)
        #endif
    }

    // MARK: – Lock screen / remote controls
    private func setupRemoteCommands() {
        #if os(iOS)
        let rc = MPRemoteCommandCenter.shared()

        rc.playCommand.isEnabled = true
        rc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.playState != .playing { self.togglePlayPause() }
            return .success
        }

        rc.pauseCommand.isEnabled = true
        rc.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.playState == .playing { self.togglePlayPause() }
            return .success
        }

        rc.togglePlayPauseCommand.isEnabled = true
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }

        rc.nextTrackCommand.isEnabled = true
        rc.nextTrackCommand.addTarget { [weak self] _ in
            self?.skip(by: 1); return .success
        }

        rc.previousTrackCommand.isEnabled = true
        rc.previousTrackCommand.addTarget { [weak self] _ in
            self?.skip(by: -1); return .success
        }
        #endif
    }

    private func setupInterruptionHandling() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        #endif
    }

    #if os(iOS)
    @objc private func handleInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if playState == .playing {
                synth.pauseSpeaking(at: .word)
                playState = .paused
                savePosition()
            }
        case .ended:
            if let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                if opts.contains(.shouldResume) {
                    activateAudioSession()
                    togglePlayPause()
                }
            }
        @unknown default: break
        }
    }
    #endif

    // MARK: – Now Playing info (lock screen)
    private func updateNowPlaying() {
        #if os(iOS)
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let secsPerPara: Double = 40
        let total    = Double(track.paragraphs.count) * secsPerPara
        let elapsed  = Double(currentParagraph) * secsPerPara

        var info: [String: Any] = [
            MPMediaItemPropertyTitle:          track.chapter,
            MPMediaItemPropertyArtist:         track.publication,
            MPMediaItemPropertyAlbumTitle:     "CGRC Trainer",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration:    total,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate:
                playState == .playing ? 1.0 : 0.0,
        ]

        // Show app icon as artwork
        if let img = UIImage(named: "CGRCIcon") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: img.size) { _ in img }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    // MARK: – Playback control

    /// Start a track from a specific paragraph.
    /// Only call this when the user intentionally picks a NEW track.
    func play(track: AudioTrack, from paragraph: Int = 0) {
        manualStop()
        self.track        = track
        currentTrackID    = track.id
        currentParagraph  = paragraph
        savePosition()
        activateAudioSession()
        speakCurrent()
    }

    /// Resume from saved position on the current track without restarting.
    func resumeFromSaved() {
        guard track != nil else { return }
        activateAudioSession()
        speakCurrent()
    }

    func togglePlayPause() {
        switch playState {
        case .stopped, .paused:
            if synth.isPaused {
                activateAudioSession()
                synth.continueSpeaking()
                playState = .playing
            } else {
                activateAudioSession()
                speakCurrent()
            }
        case .playing:
            synth.pauseSpeaking(at: .word)
            playState = .paused
            savePosition()
            updateNowPlaying()
        }
    }

    /// Pause without losing position (used by Done button).
    func pauseForBackground() {
        if playState == .playing {
            synth.pauseSpeaking(at: .word)
            playState = .paused
            updateNowPlaying()
        }
        savePosition()
    }

    func skip(by delta: Int) {
        guard let track else { return }
        let next = currentParagraph + delta
        guard next >= 0, next < track.paragraphs.count else { return }
        manualStop()
        currentParagraph = next
        savePosition()
        activateAudioSession()
        speakCurrent()
    }

    private func manualStop() {
        suppressNextDidFinish = true
        synth.stopSpeaking(at: .immediate)
        playState = .stopped
    }

    // MARK: – Voice

    private var preferredVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.name.caseInsensitiveCompare("Zoe") == .orderedSame &&
            $0.language.hasPrefix("en")
        }) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: – Internal speak

    private func speakCurrent() {
        guard let track, currentParagraph < track.paragraphs.count else {
            playState = .stopped
            updateNowPlaying()
            return
        }
        let utt = AVSpeechUtterance(string: track.paragraphs[currentParagraph])
        utt.rate            = rate
        utt.pitchMultiplier = 1.0
        utt.voice           = preferredVoice
        playState = .playing
        synth.speak(utt)
        updateNowPlaying()
    }

    // MARK: – Delegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didFinish utterance: AVSpeechUtterance) {
        if suppressNextDidFinish { suppressNextDidFinish = false; return }

        guard let track else { playState = .stopped; return }
        let nextPara = currentParagraph + 1
        if nextPara < track.paragraphs.count {
            currentParagraph = nextPara
            savePosition()
            speakCurrent()
        } else if let idx = AUDIO_LIBRARY.firstIndex(where: { $0.id == track.id }),
                  idx + 1 < AUDIO_LIBRARY.count {
            let next   = AUDIO_LIBRARY[idx + 1]
            self.track = next
            currentTrackID   = next.id
            currentParagraph = 0
            savePosition()
            speakCurrent()
        } else {
            playState = .stopped
        }
    }
}

// MARK: – Audio Library View
struct AudioLibraryView: View {
    @StateObject private var engine = SpeechEngine()
    @State private var selectedPub: String? = AUDIO_PUBLICATIONS.first
    @State private var showingPlayer = false
    @State private var chosenTrack: AudioTrack? = nil

    var tracksForSelected: [AudioTrack] {
        guard let pub = selectedPub else { return [] }
        return AUDIO_LIBRARY.filter { $0.publication == pub }
    }

    var body: some View {
        NavigationStack {
            List {
                // Resume banner — shown when a saved position exists
                if let tid = engine.currentTrackID,
                   let t   = AUDIO_LIBRARY.first(where: { $0.id == tid }),
                   engine.playState != .playing {
                    Section {
                        Button {
                            chosenTrack = t
                            showingPlayer = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2).foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Resume")
                                        .font(.subheadline).bold()
                                    Text("\(t.publication) · \(t.chapter)")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text("Section \(engine.currentParagraph + 1) of \(t.paragraphs.count)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section("Publication") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AUDIO_PUBLICATIONS, id: \.self) { pub in
                                Button(pub) { selectedPub = pub }
                                    .buttonStyle(.bordered)
                                    .tint(selectedPub == pub ? .blue : .gray)
                                    .font(.footnote)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }

                Section("Chapters") {
                    ForEach(tracksForSelected) { track in
                        Button {
                            chosenTrack = track
                            // Only start fresh if user taps a DIFFERENT track
                            if engine.currentTrackID != track.id {
                                engine.play(track: track)
                            }
                            showingPlayer = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.chapter).font(.subheadline)
                                    Text("\(track.paragraphs.count) sections")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if engine.currentTrackID == track.id {
                                    Image(systemName: engine.playState == .playing
                                          ? "waveform" : "pause.fill")
                                        .foregroundStyle(.blue)
                                        .font(.footnote)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Audio Study")
            .sheet(isPresented: $showingPlayer) {
                if let track = chosenTrack {
                    AudioPlayerSheet(startTrack: track, engine: engine)
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }
}

// MARK: – Player Sheet
struct AudioPlayerSheet: View {
    let startTrack: AudioTrack
    @ObservedObject var engine: SpeechEngine
    @Environment(\.dismiss) var dismiss

    private let rates: [(label: String, value: Float)] = [
        ("0.75×", 0.40), ("1×", 0.50), ("1.25×", 0.57), ("1.5×", 0.63), ("2×", 0.75)
    ]
    @State private var rateIndex = 1

    var activeTrack: AudioTrack {
        AUDIO_LIBRARY.first(where: { $0.id == engine.currentTrackID }) ?? startTrack
    }

    var progress: Double {
        let count = activeTrack.paragraphs.count
        guard count > 1 else { return 0 }
        return Double(engine.currentParagraph) / Double(count - 1)
    }

    var playIcon: String {
        engine.playState == .playing ? "pause.circle.fill" : "play.circle.fill"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeTrack.publication).font(.caption).foregroundStyle(.secondary)
                    Text(activeTrack.chapter).font(.headline).lineLimit(2)
                }
                Spacer()
                // Done: pause (keep position) then dismiss
                Button("Done") {
                    engine.pauseForBackground()
                    dismiss()
                }
                .foregroundStyle(.blue)
            }
            .padding()
            .animation(.easeInOut, value: engine.currentTrackID)

            Divider()

            // Read-along text
            ScrollView {
                let para = engine.currentParagraph
                if para < activeTrack.paragraphs.count {
                    Text(activeTrack.paragraphs[para])
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut, value: para)
                }
            }
            .frame(maxHeight: 220)

            Divider()

            // Progress
            VStack(spacing: 6) {
                ProgressView(value: progress).padding(.horizontal).tint(.blue)
                HStack {
                    Text("Section \(engine.currentParagraph + 1) of \(activeTrack.paragraphs.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)

            // Transport controls
            HStack(spacing: 36) {
                Button { engine.skip(by: -1) } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .disabled(engine.currentParagraph == 0)

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: playIcon)
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)
                }

                Button { engine.skip(by: 1) } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                .disabled(engine.currentParagraph >= activeTrack.paragraphs.count - 1
                          && AUDIO_LIBRARY.last?.id == engine.currentTrackID)
            }
            .padding(.vertical, 12)

            // Speed picker
            HStack(spacing: 8) {
                ForEach(rates.indices, id: \.self) { i in
                    Button(rates[i].label) {
                        rateIndex = i
                        engine.rate = rates[i].value
                        if engine.playState == .playing {
                            engine.play(track: activeTrack,
                                        from: engine.currentParagraph)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(rateIndex == i ? .blue : .gray)
                    .font(.footnote)
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            // If sheet opens and engine is paused/stopped at a saved position,
            // don't auto-play — let user choose to hit play.
            // If engine is already playing (track row tapped), do nothing.
            // Only start fresh if this is the very first open ever (no track).
            guard engine.currentTrackID == nil else { return }
            engine.play(track: startTrack)
        }
    }
}
