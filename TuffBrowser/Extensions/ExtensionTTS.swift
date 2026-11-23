import AVFoundation
import AppKit
import WebKit

/// Native `chrome.tts` and `chrome.ttsEngine` for extensions, combining `AVSpeechSynthesizer`
/// system voices with custom speech engines registered by extensions (via manifest `tts_engine.voices`
/// or `ttsEngine.updateVoices`). Events travel through `ExtensionEventPush`.
///
/// `AVSpeechSynthesizerDelegate` requires `Sendable`. All state is touched on the main thread.
final class ExtensionTTS: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = ExtensionTTS()

    struct EngineVoice: Equatable {
        let extensionID: String
        let voiceName: String
        let lang: String?
        let gender: String?
        let remote: Bool
        let eventTypes: [String]

        var dictionary: [String: Any] {
            var dict: [String: Any] = [
                "voiceName": voiceName,
                "extensionId": extensionID,
                "remote": remote,
            ]
            if let lang { dict["lang"] = lang }
            if let gender { dict["gender"] = gender }
            if !eventTypes.isEmpty { dict["eventTypes"] = eventTypes }
            return dict
        }
    }

    struct ActiveEngineSpeech {
        let requestID: Int
        let utteranceID: Int
        let callerExtensionID: String
        let engineExtensionID: String
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var nextUtteranceID = 1
    private var nextRequestID = 1
    /// Maps each in-flight system utterance to its chrome utterance id and owning extension.
    private var utteranceIDs: [ObjectIdentifier: Int] = [:]
    private var utteranceOwners: [ObjectIdentifier: String] = [:]
    /// Custom voices registered by extensions (extensionID -> voices).
    private(set) var engineVoices: [String: [EngineVoice]] = [:]
    /// Currently speaking utterance delegated to a `ttsEngine` extension, if any.
    private(set) var activeEngineSpeech: ActiveEngineSpeech?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Extension lifecycle & ttsEngine.updateVoices

    func extensionLoaded(_ extensionID: String, manifest: [String: Any]) {
        guard let ttsEngine = manifest["tts_engine"] as? [String: Any],
              let rawVoices = ttsEngine["voices"] as? [[String: Any]], !rawVoices.isEmpty else { return }
        let parsed = rawVoices.compactMap { Self.parseVoice($0, extensionID: extensionID, manifestStyle: true) }
        guard !parsed.isEmpty else { return }
        engineVoices[extensionID] = parsed
        notifyVoicesChanged()
    }

    func extensionUnloaded(_ extensionID: String) {
        let hadVoices = engineVoices.removeValue(forKey: extensionID) != nil
        if let active = activeEngineSpeech, active.engineExtensionID == extensionID {
            activeEngineSpeech = nil
            ExtensionEventPush.shared.emit(
                "tts.onEvent",
                args: [["type": "interrupted", "utteranceId": String(active.utteranceID)]],
                to: active.callerExtensionID
            )
        }
        if hadVoices { notifyVoicesChanged() }
    }

    func updateVoices(_ rawVoices: [[String: Any]], extensionID: String) {
        let parsed = rawVoices.compactMap { Self.parseVoice($0, extensionID: extensionID, manifestStyle: false) }
        let previous = engineVoices[extensionID] ?? []
        if parsed.isEmpty {
            engineVoices.removeValue(forKey: extensionID)
        } else {
            engineVoices[extensionID] = parsed
        }
        if previous != parsed { notifyVoicesChanged() }
    }

    private func notifyVoicesChanged() {
        ExtensionEventPush.shared.emit("tts.onVoicesChanged", args: [])
    }

    private static func parseVoice(_ dict: [String: Any], extensionID: String, manifestStyle: Bool) -> EngineVoice? {
        let name = (dict["voiceName"] as? String) ?? (manifestStyle ? dict["voice_name"] as? String : nil)
        guard let name, !name.isEmpty else { return nil }
        let lang = dict["lang"] as? String
        let gender = dict["gender"] as? String
        let remote = dict["remote"] as? Bool ?? false
        let events = (dict["eventTypes"] as? [String]) ?? (manifestStyle ? dict["event_types"] as? [String] : nil) ?? []
        return EngineVoice(extensionID: extensionID, voiceName: name, lang: lang, gender: gender, remote: remote, eventTypes: events)
    }

    /// Finds an extension-provided voice matching the `tts.speak` options, if any.
    func matchingEngineVoice(for options: [String: Any]) -> EngineVoice? {
        let all = engineVoices.values.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        let wantedExt = options["extensionId"] as? String
        let wantedName = options["voiceName"] as? String
        let wantedLang = (options["lang"] as? String)?.lowercased()
        let pool = wantedExt.map { id in all.filter { $0.extensionID == id } } ?? all
        if let wantedName {
            return pool.first { $0.voiceName == wantedName }
        }
        if wantedExt != nil {
            if let wantedLang, let byLang = pool.first(where: { $0.lang?.lowercased() == wantedLang }) { return byLang }
            return pool.first
        }
        return nil
    }

    // MARK: chrome.tts

    func speak(options: [String: Any], extensionID: String, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        guard let text = options["utterance"] as? String, !text.isEmpty else {
            fail(error("utterance is required."))
            return
        }
        let enqueue = options["enqueue"] as? Bool ?? false
        if !enqueue { stopCurrent(notifyInterrupted: true) }

        let utteranceID = nextUtteranceID
        nextUtteranceID += 1

        // Route to a ttsEngine extension when one matches the requested voice/extension.
        if let engineVoice = matchingEngineVoice(for: options) {
            let requestID = nextRequestID
            nextRequestID += 1
            activeEngineSpeech = ActiveEngineSpeech(
                requestID: requestID, utteranceID: utteranceID,
                callerExtensionID: extensionID, engineExtensionID: engineVoice.extensionID
            )
            var speakOptions: [String: Any] = ["voiceName": engineVoice.voiceName]
            if let lang = options["lang"] as? String ?? engineVoice.lang { speakOptions["lang"] = lang }
            if let rate = options["rate"] as? Double { speakOptions["rate"] = rate }
            if let pitch = options["pitch"] as? Double { speakOptions["pitch"] = pitch }
            if let volume = options["volume"] as? Double { speakOptions["volume"] = volume }
            if let gender = options["gender"] as? String { speakOptions["gender"] = gender }
            ExtensionEventPush.shared.emit(
                "ttsEngine.onSpeak",
                args: [text, speakOptions],
                extra: ["ttsRequestId": requestID],
                to: engineVoice.extensionID
            )
            finish(String(utteranceID))
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
        utteranceIDs[key] = utteranceID
        utteranceOwners[key] = extensionID
        synthesizer.speak(utterance)
        finish(String(utteranceID))
    }

    func sendTtsEvent(requestID: Int, event: [String: Any], from engineExtensionID: String) throws {
        guard let active = activeEngineSpeech, active.requestID == requestID, active.engineExtensionID == engineExtensionID else {
            throw error("No active TTS request with id \(requestID).")
        }
        var payload = event
        let type = (payload["type"] as? String) ?? "error"
        payload["type"] = type
        payload["utteranceId"] = String(active.utteranceID)
        if ["end", "interrupted", "cancelled", "error"].contains(type) {
            activeEngineSpeech = nil
        }
        ExtensionEventPush.shared.emit("tts.onEvent", args: [payload], to: active.callerExtensionID)
    }

    private func stopCurrent(notifyInterrupted: Bool) {
        if let active = activeEngineSpeech {
            activeEngineSpeech = nil
            ExtensionEventPush.shared.emit("ttsEngine.onStop", args: [], to: active.engineExtensionID)
            if notifyInterrupted {
                ExtensionEventPush.shared.emit(
                    "tts.onEvent",
                    args: [["type": "interrupted", "utteranceId": String(active.utteranceID)]],
                    to: active.callerExtensionID
                )
            }
        }
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func stop(finish: @escaping (Any?) -> Void) {
        stopCurrent(notifyInterrupted: true)
        finish(nil)
    }

    func pause(finish: @escaping (Any?) -> Void) {
        if let active = activeEngineSpeech {
            ExtensionEventPush.shared.emit("ttsEngine.onPause", args: [], to: active.engineExtensionID)
        } else {
            synthesizer.pauseSpeaking(at: .immediate)
        }
        finish(nil)
    }

    func resume(finish: @escaping (Any?) -> Void) {
        if let active = activeEngineSpeech {
            ExtensionEventPush.shared.emit("ttsEngine.onResume", args: [], to: active.engineExtensionID)
        } else {
            synthesizer.continueSpeaking()
        }
        finish(nil)
    }

    func isSpeaking(finish: @escaping (Any?) -> Void) {
        finish(synthesizer.isSpeaking || activeEngineSpeech != nil)
    }

    func getVoices(finish: @escaping (Any?) -> Void) {
        let custom = engineVoices.values.flatMap { $0 }.map(\.dictionary)
        let system = AVSpeechSynthesisVoice.speechVoices().map { voice -> [String: Any] in
            [
                "voiceName": voice.name,
                "lang": voice.language,
                "gender": voice.gender == .female ? "female" : "male",
                "remote": false,
            ]
        }
        finish(custom + system)
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
