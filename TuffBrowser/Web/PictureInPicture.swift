import AppKit
import WebKit

/// Picture in picture for page video.
///
/// WebKit ships with PiP switched off for every app but Safari: the preference behind it,
/// `allowsPictureInPictureMediaPlayback`, is private and defaults to false, which leaves sites'
/// own PiP buttons, the video context menu's "Enter Picture in Picture" and
/// `requestPictureInPicture()` all dead. `enable(_:)` turns it on.
///
/// A small script in every frame (in Tuff's content world, out of the page's reach) tells the
/// tab when one of its videos enters or leaves PiP, and does the entering and leaving when the
/// app asks: the menu command, the sidebar button, and popping a playing video out when you
/// switch away from its tab. Calls from the app count as a user gesture, which PiP requires.
enum PictureInPicture {
    static let handlerName = "tuffPiP"
    static let world = WebEngine.scriptWorld
    private static let handler = PictureInPictureMessageHandler()

    /// What the page script did when asked.
    enum Outcome: String {
        case entered, exited, none, failed
    }

    enum Mode: String {
        /// Leave PiP if a video is in it, else put the best video on the page into it.
        case toggle
        /// Only a video that is playing with sound, and is big enough to be the point of the page.
        case auto
        case exit
        /// Play on a video that WebKit paused as it left PiP (see `exitPaused` in the script).
        case resume
    }

    static func enable(_ preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) else { return }
        preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
    }

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(handler, contentWorld: world, name: handlerName)
    }

    /// Runs the page script in one frame (nil = the main frame).
    static func run(_ mode: Mode, in webView: WKWebView, frame: WKFrameInfo?, completion: @escaping (Outcome) -> Void) {
        webView.callAsyncJavaScript(
            "return window.__tuffPiP ? await window.__tuffPiP(mode) : 'none'",
            arguments: ["mode": mode.rawValue], in: frame, in: world
        ) { result in
            switch result {
            case .success(let value): completion((value as? String).flatMap(Outcome.init) ?? .none)
            case .failure(let error):
                ExtensionManager.shared.trace("pip \(mode.rawValue) script failed: \(error.localizedDescription)")
                completion(.none)
            }
        }
    }

    private static let script = #"""
    (function () {
      if (window.__tuffPiP) return;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuffPiP;
      if (!bridge) return;

      function post(message) { try { bridge.postMessage(message); } catch (e) {} }

      function pipVideo() {
        var el = document.pictureInPictureElement;
        if (el) return el;
        var videos = document.getElementsByTagName('video');
        for (var i = 0; i < videos.length; i++) {
          if (videos[i].webkitPresentationMode === 'picture-in-picture') return videos[i];
        }
        return null;
      }

      // A video in a tab that isn't on screen is paused by WebKit as it leaves PiP, whichever way
      // it leaves (the window's "back to tab" button included). That pause comes with the video
      // already out of PiP mode, unlike one the user makes with the PiP window's own controls
      // (its close button pauses first), so it is remembered here: the video was still playing.
      var exitPaused = null;

      // On leaving PiP no video is in it any more, so `playing` comes from the event's video.
      function report(e) {
        var v = pipVideo();
        var subject = v || (e && e.target && e.target.tagName === 'VIDEO' ? e.target : null);
        post({ pip: !!v, playing: !!subject && (!subject.paused || subject === exitPaused) });
      }

      // `disablePictureInPicture` is ignored: sites (Netflix among them) set it to hide the
      // browser's own PiP button, but this only runs when the user asked for PiP.
      function canPiP(v) {
        if (v.readyState < 1 || !v.videoWidth) return false;
        return v.webkitSupportsPresentationMode ? v.webkitSupportsPresentationMode('picture-in-picture') : true;
      }

      function area(v) {
        var r = v.getBoundingClientRect();
        return Math.max(0, r.width) * Math.max(0, r.height);
      }

      // The video PiP should take: one that is playing beats one that isn't, then the biggest.
      function best(mode) {
        var videos = document.getElementsByTagName('video');
        var pick = null, pickScore = -1;
        for (var i = 0; i < videos.length; i++) {
          var v = videos[i];
          if (!canPiP(v)) continue;
          var playing = !v.paused && !v.ended;
          var size = area(v);
          if (mode === 'auto') {
            // Muted autoplay loops are decoration, not something you were watching.
            if (!playing || v.muted || v.volume === 0 || size < 200 * 120) continue;
          }
          var score = size + (playing ? 1e9 : 0);
          if (score > pickScore) { pick = v; pickScore = score; }
        }
        return pick;
      }

      // requestPictureInPicture() rejects while the flag is set, so it is cleared first (and left
      // cleared: setting it again on a video in PiP takes it out).
      async function enter(v) {
        if (v.disablePictureInPicture) v.disablePictureInPicture = false;
        if (v.requestPictureInPicture) {
          try { await v.requestPictureInPicture(); return; } catch (e) { if (!v.webkitSetPresentationMode) throw e; }
        }
        v.webkitSetPresentationMode('picture-in-picture');
      }

      async function exit(v) {
        if (document.pictureInPictureElement && document.exitPictureInPicture) await document.exitPictureInPicture();
        else v.webkitSetPresentationMode('inline');
      }

      window.__tuffPiP = async function (mode) {
        try {
          if (mode === 'resume') {
            var paused = exitPaused;
            exitPaused = null;
            if (!paused || !paused.paused) return 'none';
            await paused.play();
            return 'entered';
          }
          var current = pipVideo();
          if (current) {
            if (mode === 'auto') return 'none';
            await exit(current);
            return 'exited';
          }
          if (mode === 'exit') return 'none';
          if (mode === 'auto' && document.fullscreenElement) return 'none';
          var v = best(mode);
          if (!v) return 'none';
          await enter(v);
          return 'entered';
        } catch (e) {
          return 'failed';
        }
      };

      ['enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged'].forEach(function (type) {
        document.addEventListener(type, function (e) { setTimeout(function () { report(e); }, 0); }, true);
      });
      document.addEventListener('pause', function (e) {
        var v = e.target;
        if (v.tagName === 'VIDEO' && v === document.pictureInPictureElement && v.webkitPresentationMode !== 'picture-in-picture') exitPaused = v;
      }, true);
      document.addEventListener('play', function (e) { if (e.target === exitPaused) exitPaused = null; }, true);
      // Lets the app find a video that plays in a subframe (an embedded player).
      document.addEventListener('play', function (e) {
        if (e.target && e.target.tagName === 'VIDEO' && window !== window.top) post({ playing: true });
      }, true);
    })();
    """#
}

final class PictureInPictureMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab = (message.webView as? TuffWebView)?.tab,
              let body = message.body as? [String: Any] else { return }
        let playing = (body["playing"] as? Bool) ?? false
        if let pip = body["pip"] as? Bool {
            tab.pictureInPictureDidChange(active: pip, playing: playing, frame: message.frameInfo)
        } else if playing, !message.frameInfo.isMainFrame {
            tab.mediaFrame = message.frameInfo
        }
    }
}

// MARK: - Tab

extension Tab {
    /// Puts the page's video into PiP, or takes it out. Calls back with what happened.
    func togglePictureInPicture(completion: ((PictureInPicture.Outcome) -> Void)? = nil) {
        runPictureInPicture(.toggle) { [weak self] outcome in
            if outcome == .entered { self?.enteredPictureInPictureAutomatically = false }
            completion?(outcome)
        }
    }

    /// Called when the tab stops being the one on screen: pops a video playing with sound out.
    func enterPictureInPictureAutomatically() {
        guard webView != nil, isPlayingAudio, !isMuted, !isInPictureInPicture else {
            ExtensionManager.shared.trace("pip auto skipped: awake=\(webView != nil) audio=\(isPlayingAudio) muted=\(isMuted) pip=\(isInPictureInPicture)")
            return
        }
        runPictureInPicture(.auto) { [weak self] outcome in
            ExtensionManager.shared.trace("pip auto: \(outcome.rawValue)")
            if outcome == .entered { self?.enteredPictureInPictureAutomatically = true }
        }
    }

    /// Called when the tab is back on screen: returns a video that went into PiP on its own.
    func leaveAutomaticPictureInPicture() {
        guard isInPictureInPicture, enteredPictureInPictureAutomatically else { return }
        enteredPictureInPictureAutomatically = false
        runPictureInPicture(.exit) { _ in }
    }

    /// Tries the main frame, then the frame PiP is in, then the last subframe that played video.
    private func runPictureInPicture(_ mode: PictureInPicture.Mode, completion: @escaping (PictureInPicture.Outcome) -> Void) {
        guard let webView else { completion(.none); return }
        var frames: [WKFrameInfo?] = [nil]
        if let frame = pictureInPictureFrame, !frame.isMainFrame { frames.insert(frame, at: 0) }
        if let frame = mediaFrame, !frame.isMainFrame { frames.append(frame) }

        func attempt(_ index: Int) {
            guard index < frames.count else { completion(.none); return }
            PictureInPicture.run(mode, in: webView, frame: frames[index]) { outcome in
                if outcome == .none { attempt(index + 1) } else { completion(outcome) }
            }
        }
        attempt(0)
    }

    func pictureInPictureDidChange(active: Bool, playing: Bool, frame: WKFrameInfo) {
        if active { pictureInPictureFrame = frame }
        guard active != isInPictureInPicture else { return }
        isInPictureInPicture = active
        guard !active else { return }
        pictureInPictureFrame = nil
        enteredPictureInPictureAutomatically = false
        // The PiP window's close button pauses the video; its "back to the page" button leaves it
        // playing (or, in a tab that was in the background, paused by WebKit on the way out: the
        // page script knows). For the second, show the page it went back to, and carry on playing.
        if playing, let browser, !browser.isOnScreen(self) {
            browser.select(self)
            NSApp.activate()
            browser.window?.makeKeyAndOrderFront(nil)
            if let webView {
                PictureInPicture.run(.resume, in: webView, frame: frame) { _ in }
            }
        }
    }
}
