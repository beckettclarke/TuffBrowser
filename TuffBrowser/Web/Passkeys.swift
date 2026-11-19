import Security
import WebKit

/// Passkeys need Apple's `com.apple.developer.web-browser.public-key-credential` entitlement,
/// which Tuff doesn't have yet: without it every `navigator.credentials.create` / `get` with a
/// public key fails at once. WebKit still tells pages otherwise. `getClientCapabilities()`
/// answers that a platform authenticator, conditional sign-in and phones (hybrid) all work, so
/// sign-in pages (Google's among them) send you to their passkey step, it fails, they send you
/// back, and round it goes: a redirect loop that breaks the page.
///
/// Until Tuff has the entitlement, a small script makes `getClientCapabilities()` say what is
/// true, so sites offer a password or another way in. A password manager extension that
/// handles passkeys itself (1Password, Bitwarden) replaces `navigator.credentials.create` /
/// `get` in the page; then WebKit's own answer stands, and the extension's passkeys work as before.
enum Passkeys {
    /// Whether this build may use passkeys through WebKit (the entitlement is present).
    static let available: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
        return (value as? Bool) == true
    }()

    static func install(into controller: WKUserContentController) {
        guard !available else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    private static let script = #"""
    (function () {
      var PKC = window.PublicKeyCredential;
      if (!PKC || typeof PKC.getClientCapabilities !== 'function' || !navigator.credentials) return;
      var original = PKC.getClientCapabilities;
      var source = Function.prototype.toString;
      var isNative = function (f) { try { return typeof f === 'function' && /\[native code\]/.test(source.call(f)); } catch (e) { return false; } };
      // An extension provides passkeys when it has replaced WebKit's own functions.
      var extensionProvides = function () {
        return !isNative(navigator.credentials.get) || !isNative(navigator.credentials.create);
      };
      var wrapped = function getClientCapabilities() {
        if (extensionProvides()) return original.apply(this, arguments);
        return original.apply(this, arguments).then(function (capabilities) {
          var honest = {};
          for (var name in capabilities) honest[name] = false;
          return honest;
        });
      };
      try { wrapped.toString = function () { return 'function getClientCapabilities() {\n    [native code]\n}'; }; } catch (e) {}
      try { Object.defineProperty(PKC, 'getClientCapabilities', { value: wrapped, writable: true, configurable: true }); } catch (e) {}
    })();
    """#
}
