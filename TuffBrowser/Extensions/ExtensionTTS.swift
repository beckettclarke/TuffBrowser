import AVFoundation
import AppKit

/// Native `chrome.tts` for extensions, on top of `AVSpeechSynthesizer`. Method calls are routed here by
/// `ExtensionAPIBridge`; the `onEvent` stream (start / end / interrupted / paused / resumed) is pushed
/// back to the speaking extension through `ExtensionEventPush`.
///
/// `AVSpeechSynthesizerDelegate` requires `Sendable`. The state here is only touched on the main
/// thread: API calls arrive there, and the delegate callbacks hop there before doing anything.
final class ExtensionTTS: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = ExtensionTTS()

    private let synthesizer = AVSpeechSynthesizer()
    private var nextUtteranceID = 1
    /// Maps each in-flight utterance to its chrome utterance id and owning extension.
    private var utteranceIDs: [ObjectIdentifier: Int] = [:]
    private var utteranceOwners: [ObjectIdentifier: String] = [:]

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func speak(options: [String: Any], extensionID: String, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let text = options["utterance"] as? String, !text.isEmpty else {
            fail(error("utterance is required."))
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        if let rate = options["rate"] as? Double {
            // Chrome rate is ~0.1…10 with 1 = normal; AVSpeech is 0…1 with 0.5 = normal.
            utterance.rate = min(1, max(0, Float(rate * 0.5)))
        }
        if let pitch = options["pitch"] as? Double {
            utterance.pitchMultiplier = min(2, max(0.5, Float(pitch)))
        }
        if let volume = options["volume"] as? Double {
            utterance.volume = min(1, max(0, Float(volume)))
        }
        if let lang = options["lang"] as? String, let voice = AVSpeechSynthesisVoice(language: lang) {
            utterance.voice = voice
        }
        if let name = options["voiceName"] as? String,
           let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) {
            utterance.voice = voice
        }
        let key = ObjectIdentifier(utterance)
        utteranceIDs[key] = nextUtteranceID
        utteranceOwners[key] = extensionID
        nextUtteranceID += 1
        synthesizer.speak(utterance)
        finish(nil)
    }

    func stop(finish: @escaping (Any?) -> Void) {
        synthesizer.stopSpeaking(at: .immediate)
        finish(nil)
    }

    func pause(finish: @escaping (Any?) -> Void) {
        synthesizer.pauseSpeaking(at: .immediate)
        finish(nil)
    }

    func resume(finish: @escaping (Any?) -> Void) {
        synthesizer.continueSpeaking()
        finish(nil)
    }

    func isSpeaking(finish: @escaping (Any?) -> Void) {
        finish(synthesizer.isSpeaking)
    }

    func getVoices(finish: @escaping (Any?) -> Void) {
        let voices = AVSpeechSynthesisVoice.speechVoices().map { voice -> [String: Any] in
            [
                "voiceName": voice.name,
                "lang": voice.language,
                "gender": voice.gender == .female ? "female" : "male",
                "remote": false,
            ]
        }
        finish(voices)
    }

    // MARK: AVSpeechSynthesizerDelegate → chrome.tts.onEvent

    private func push(_ type: String, _ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let id = utteranceIDs[key], let owner = utteranceOwners[key] else { return }
        ExtensionEventPush.shared.emit("tts.onEvent", args: [["type": type, "utteranceId": String(id)]], to: owner)
    }

    private func forget(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        utteranceIDs.removeValue(forKey: key)
        utteranceOwners.removeValue(forKey: key)
    }

    private func onMain(_ utterance: AVSpeechUtterance, _ body: @escaping (AVSpeechUtterance) -> Void) {
        if Thread.isMainThread { body(utterance) } else { DispatchQueue.main.async { body(utterance) } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onMain(utterance) { self.push("start", $0) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onMain(utterance) { self.push("end", $0); self.forget($0) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onMain(utterance) { self.push("interrupted", $0); self.forget($0) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        onMain(utterance) { self.push("paused", $0) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        onMain(utterance) { self.push("resumed", $0) }
    }
}