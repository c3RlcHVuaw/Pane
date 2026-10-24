import AVFoundation
import Foundation
import PaneModel
import Speech

/// Dictation for the assistant's text field: speaks in, text comes out. Uses Apple's on-device-capable recognizer.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var level: Float = 0   // 0...1, for the little level meter
    @Published var errorText: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?

    func toggle(onText: @escaping (String) -> Void) {
        if isListening { stop(); return }
        self.onText = onText
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else { self.errorText = tr("Allow speech recognition for Pane in System Settings → Privacy & Security."); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else { self.errorText = tr("Allow the microphone for Pane in System Settings → Privacy & Security."); return }
                        self.start()
                    }
                }
            }
        }
    }

    private func start() {
        errorText = nil
        let recognizer = SFSpeechRecognizer(locale: AppLanguage.currentLocale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { errorText = tr("Speech recognition isn't available right now."); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            let samples = buffer.floatChannelData?[0]
            var peak: Float = 0
            if let samples { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) } }
            Task { @MainActor in self?.level = min(1, peak * 3) }
        }
        do { engine.prepare(); try engine.start() } catch { errorText = tr("Couldn't start the microphone."); return }
        isListening = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.onText?(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    func stop() {
        guard isListening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false; level = 0
    }
}
