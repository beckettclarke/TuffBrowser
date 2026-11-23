import AppKit
import SwiftUI
import WebKit

/// The sign-in field that has the keyboard, and what Tuff can fill into it.
struct PasswordSuggestions: Identifiable {
    enum Field: String { case username, password, newPassword = "new-password" }

    let id = UUID()
    let frame: WKFrameInfo
    let origin: String
    let field: Field
    /// Where the field is, in the web view's points; nil for a field in a frame inside the
    /// page, whose position on screen isn't known.
    let rect: CGRect?
    var logins: [SavedLogin]
    /// Offered for a new-password field (signing up, changing a password).
    var strongPassword: String?
    /// The row picked with the arrow keys; Return fills it.
    var highlighted: Int?

    var count: Int { logins.count + (strongPassword == nil ? 0 : 1) }
}

/// A sign-in the page just sent, waiting to be offered for saving.
struct CapturedLogin: Equatable {
    var origin: String
    var username: String
    var password: String
    var profile: UUID
}

/// Saving and filling passwords in pages. A script in Tuff's content world (pages can't see
/// it or its messages) reports when a sign-in field gets the keyboard and when a form with a
/// password is sent; Tuff lists matching logins under the field (`PasswordSuggestionList`) and
/// offers to save new ones on a card after the page moves on.
enum PasswordAutofill {
    static let world = WebEngine.scriptWorld
    static let handlerName = "tuffPasswords"
    private static let handler = MessageHandler()

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        controller.add(handler, contentWorld: world, name: handlerName)
    }

    static var enabled: Bool { AppSettings.shared.privacy.passwords }

    /// 20 characters from an alphabet without look-alikes, in dash-separated groups of five, as
    /// Safari makes them: about 110 bits, and sites that want a symbol or digit get both.
    static func strongPassword() -> String {
        let lower = Array("abcdefghjkmnpqrstuvwxyz"), upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ"), digits = Array("23456789")
        let all = lower + upper + digits
        var chars = (0..<18).map { _ in all.randomElement()! }
        chars.insert(upper.randomElement()!, at: Int.random(in: 0...chars.count))
        chars.insert(digits.randomElement()!, at: Int.random(in: 0...chars.count))
        let groups = stride(from: 0, to: 20, by: 5).map { String(chars[$0..<$0 + 5]) }
        return groups.joined(separator: "-")
    }

    /// Fills a saved login (or with only a password, a new strong password) into the field the
    /// suggestions are for. The script checks the frame is still on the same origin first.
    static func fill(_ suggestions: PasswordSuggestions, login: SavedLogin?, newPassword: String?, in tab: Tab) {
        guard let webView = tab.webView else { return }
        let arguments: [String: Any] = [
            "origin": suggestions.origin,
            "username": login?.username ?? "",
            "password": login?.password ?? newPassword ?? "",
            "isNew": newPassword != nil,
        ]
        webView.callAsyncJavaScript(
            "return window.__tuffPasswords ? window.__tuffPasswords.fill(origin, username, password, isNew) : false",
            arguments: arguments, in: suggestions.frame, in: world
        ) { _ in }
        if let login { PasswordStore.shared.markUsed(login.id) }
        tab.passwordSuggestions = nil
    }

    // MARK: Messages

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard PasswordAutofill.enabled, let webView = message.webView as? TuffWebView, let tab = webView.tab,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            // The frame's real origin, not anything the page could claim.
            let securityOrigin = message.frameInfo.securityOrigin
            let scheme = securityOrigin.protocol.lowercased()
            guard scheme == "https" || scheme == "http" else { return }
            let origin = SitePermissions.origin(of: securityOrigin)
            switch type {
            case "focus":
                guard let profile = tab.passwordProfileID,
                      let field = PasswordSuggestions.Field(rawValue: body["field"] as? String ?? "") else { return }
                let logins = field == .newPassword ? [] : PasswordStore.shared.logins(for: origin, profile: profile)
                let strong = field == .newPassword ? PasswordAutofill.strongPassword() : nil
                guard !logins.isEmpty || strong != nil else {
                    tab.passwordSuggestions = nil
                    return
                }
                var rect: CGRect?
                if message.frameInfo.isMainFrame, let r = body["rect"] as? [Double], r.count == 4 {
                    let zoom = webView.pageZoom * webView.magnification
                    rect = CGRect(x: r[0] * zoom, y: r[1] * zoom, width: r[2] * zoom, height: r[3] * zoom)
                }
                tab.passwordSuggestions = PasswordSuggestions(
                    frame: message.frameInfo, origin: origin, field: field, rect: rect, logins: logins, strongPassword: strong
                )
            case "blur":
                // A click on the list takes the keyboard from the page too; the list closes itself.
                guard let current = tab.passwordSuggestions, !PasswordSuggestionList.pointerInside else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if tab.passwordSuggestions?.id == current.id, !PasswordSuggestionList.pointerInside { tab.passwordSuggestions = nil }
                }
            case "submit":
                guard let profile = tab.passwordProfileID, let password = body["password"] as? String, !password.isEmpty else { return }
                let username = (body["username"] as? String ?? "").trimmed
                tab.captured(CapturedLogin(origin: origin, username: username, password: password, profile: profile))
            default:
                break
            }
        }
    }

    // MARK: Script

    private static let script = #"""
    (function () {
      if (window.__tuffPasswords) return;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tuffPasswords;
      if (!bridge) return;
      var post = function (m) { try { bridge.postMessage(m); } catch (e) {} };
      var textTypes = ['text', 'email', 'tel', ''];

      function isInput(el) { return el instanceof HTMLInputElement; }
      function isPassword(el) { return isInput(el) && el.type === 'password'; }
      function visible(el) {
        if (!el || el.disabled || el.readOnly) return false;
        var r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        var s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.05;
      }
      function scopeOf(el) { return (el && (el.form || el.closest('form'))) || document; }
      function inputs(scope) { return Array.prototype.slice.call(scope.querySelectorAll('input')); }
      function passwords(scope) { return inputs(scope).filter(function (i) { return isPassword(i) && visible(i); }); }
      function isUsernameLike(el) {
        if (!isInput(el) || textTypes.indexOf(el.type) < 0) return false;
        var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (ac.indexOf('username') >= 0 || ac.indexOf('email') >= 0 || ac.indexOf('webauthn') >= 0) return true;
        var hint = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || '') + ' ' + (el.getAttribute('aria-label') || '')).toLowerCase();
        return el.type === 'email' || /user|login|email|e-mail|account|identifier|phone/.test(hint);
      }
      // The text field a password belongs to: the last visible one before it in its form.
      function usernameFor(pw) {
        var all = inputs(scopeOf(pw)), index = all.indexOf(pw), best = null;
        for (var i = index - 1; i >= 0; i--) {
          var el = all[i];
          if (isInput(el) && textTypes.indexOf(el.type) >= 0 && visible(el)) { best = el; if (isUsernameLike(el)) return el; }
        }
        return best;
      }
      function isNewPassword(pw) {
        var ac = (pw.getAttribute('autocomplete') || '').toLowerCase();
        if (ac.indexOf('new-password') >= 0) return true;
        if (ac.indexOf('current-password') >= 0) return false;
        var hint = ((pw.name || '') + ' ' + (pw.id || '') + ' ' + (pw.placeholder || '')).toLowerCase();
        if (/new|confirm|repeat|retype|again|create/.test(hint)) return true;
        return passwords(scopeOf(pw)).length >= 2;
      }
      // A field that is part of a sign-in: a password, or a username-like field in a form that
      // has (or is about to show) a password.
      function fieldKind(el) {
        if (isPassword(el)) return isNewPassword(el) ? 'new-password' : 'password';
        if (!isUsernameLike(el)) return null;
        var scope = scopeOf(el);
        if (passwords(scope).length) return passwords(scope).every(isNewPassword) ? null : 'username';
        var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
        return ac.indexOf('username') >= 0 || ac.indexOf('webauthn') >= 0 ? 'username' : null;
      }

      // The listeners for every click, key press and scroll are added only once a sign-in
      // field has had the keyboard or been typed in (or filled by a password manager). Most
      // pages never have one, and on them a click costs nothing: the click handler searches the
      // document for inputs, which doubled the time of Speedometer's TodoMVC steps that click
      // or press Return 100 times.
      var armed = false;
      function isSignInField(el) { return isPassword(el) || isUsernameLike(el); }
      function arm() {
        if (armed) return;
        armed = true;
        document.removeEventListener('input', armOnInput, true);
        document.addEventListener('keydown', onKeyDown, true);
        document.addEventListener('click', onClick, true);
        window.addEventListener('scroll', onScroll, true);
      }
      function armOnInput(e) { if (isSignInField(e.target)) arm(); }
      document.addEventListener('input', armOnInput, true);

      var focused = null, filling = false;
      document.addEventListener('focusin', function (e) {
        if (filling) return;
        var el = e.target;
        if (!isSignInField(el)) return;
        arm();
        var kind = fieldKind(el);
        if (!kind) return;
        focused = el;
        var r = el.getBoundingClientRect();
        post({ type: 'focus', field: kind, rect: [r.left, r.top, r.width, r.height] });
      }, true);
      document.addEventListener('focusout', function (e) { if (e.target === focused) post({ type: 'blur' }); }, true);
      function onScroll() { if (focused) post({ type: 'blur' }); }
      // A field that took the keyboard before this script ran (autofocus).
      if (isSignInField(document.activeElement)) arm();

      // What was typed when a form with a password is sent. A form with several passwords
      // (sign-up, change password) sends the one typed twice: the new one.
      var lastSent = '';
      function capture(scope) {
        var pws = passwords(scope).filter(function (p) { return p.value; });
        if (!pws.length) return;
        var pw = pws[pws.length - 1];
        if (pws.length > 1) {
          for (var i = 0; i < pws.length; i++) {
            for (var j = i + 1; j < pws.length; j++) if (pws[i].value === pws[j].value) { pw = pws[i]; }
          }
        }
        var user = usernameFor(pw);
        var username = user ? user.value : '';
        if (!username) { try { username = sessionStorage.getItem('__tuffUsername') || ''; } catch (e) {} }
        var key = username + '\u0000' + pw.value;
        if (key === lastSent) return;
        lastSent = key;
        post({ type: 'submit', username: username, password: pw.value });
      }
      // Sign-in split over two pages (Google, Microsoft, Apple): remember the username from
      // the first step, in this tab only.
      function rememberUsername(scope) {
        var fields = inputs(scope).filter(function (i) { return isUsernameLike(i) && i.value && visible(i); });
        if (fields.length && !passwords(scope).length) { try { sessionStorage.setItem('__tuffUsername', fields[0].value); } catch (e) {} }
      }
      document.addEventListener('submit', function (e) { rememberUsername(e.target); capture(e.target); }, true);
      function onKeyDown(e) {
        if (e.key !== 'Enter' || !isInput(e.target)) return;
        rememberUsername(scopeOf(e.target)); capture(scopeOf(e.target));
      }
      function onClick(e) {
        var b = e.target && e.target.closest && e.target.closest('button, input[type=submit], input[type=button], [role=button], a');
        if (!b) return;
        var scope = scopeOf(b);
        rememberUsername(scope);
        if (passwords(scope).some(function (p) { return p.value; })) capture(scope);
        else if (scope !== document && passwords(document).some(function (p) { return p.value; })) capture(document);
      }
      window.addEventListener('pagehide', function () { capture(document); }, true);

      function setValue(el, value) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      window.__tuffPasswords = {
        fill: function (origin, username, password, isNew) {
          if (location.origin !== origin) return false;
          var el = focused && document.contains(focused) ? focused : document.activeElement;
          if (!isInput(el)) return false;
          filling = true;
          try { return fillInto(el, username, password, isNew); } finally { filling = false; }
        },
        // After a sign-in: a page still asking for a password means the site said no (most
        // show the form again, empty or not, with an error).
        asksForPassword: function () {
          return passwords(document).length > 0;
        }
      };

      function fillInto(el, username, password, isNew) {
        if (isNew) {
          var scope = scopeOf(el);
          passwords(scope).filter(function (p) { return p === el || (isNewPassword(p) && !p.value); }).forEach(function (p) { setValue(p, password); });
          setValue(el, password);
          return true;
        }
        var pw = isPassword(el) ? el : passwords(scopeOf(el))[0];
        var user = isPassword(el) ? usernameFor(el) : el;
        if (user && username) setValue(user, username);
        if (pw) setValue(pw, password);
        if (!pw && user) { try { sessionStorage.setItem('__tuffUsername', username); } catch (e) {} }
        return true;
      }
    })();
    """#
}

// MARK: - Tab

extension Tab {
    /// Whose passwords this tab uses: its profile's, or in Incognito the main window's.
    var passwordProfileID: UUID? {
        guard let browser else { return nil }
        if browser.isPrivate { return BrowserState.shared.bookmarksProfileID }
        return browser.profile(containing: self)?.id ?? browser.bookmarksProfileID
    }

    /// The page sent a sign-in. It is offered for saving once the page has moved on (the next
    /// page finishing, or after a moment for sites that sign in without one), unless it is
    /// saved already, the site is on the never list, or the page still asks for a password
    /// (the sign-in failed).
    func captured(_ login: CapturedLogin) {
        let store = PasswordStore.shared
        if store.isNever(login.origin) { return }
        let saved = store.logins(for: login.origin, profile: login.profile).filter { $0.origin == login.origin }
        if let same = saved.first(where: { $0.username == login.username && $0.password == login.password }) {
            store.markUsed(same.id)
            return
        }
        if login == pendingLogin { return }
        pendingLogin = login
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.offerPendingLogin() }
    }

    /// Asks whether to save (or update) the sign-in the page last sent.
    func offerPendingLogin() {
        guard let login = pendingLogin, !pendingLoginShowing else { return }
        pendingLogin = nil
        guard let webView else { return }
        webView.callAsyncJavaScript(
            "return window.__tuffPasswords ? window.__tuffPasswords.asksForPassword() : false",
            arguments: [:], in: nil, in: PasswordAutofill.world
        ) { [weak self] result in
            if case .success(let value) = result, value as? Bool == true { return }
            Task { @MainActor in await self?.askToSave(login) }
        }
    }

    @MainActor
    private func askToSave(_ login: CapturedLogin) async {
        let store = PasswordStore.shared
        let host = URL(string: login.origin)?.displayHost ?? login.origin
        let existing = store.logins(for: login.origin, profile: login.profile)
            .first { $0.origin == login.origin && $0.username == login.username && !login.username.isEmpty }
        let prompt = Prompt(
            icon: favicon,
            symbol: "key.fill",
            title: existing == nil ? "Save password for \(host)?" : "Update password for \(host)?",
            message: existing == nil
                ? "Tuff fills it in next time you sign in."
                : "Replace the password saved for \(login.username) with the one you just used.",
            note: login.origin.hasPrefix("http://") ? "This site doesn’t use a secure connection, so the password could be seen by others on the network." : nil,
            confirmTitle: existing == nil ? "Save" : "Update",
            cancelTitle: "Not Now",
            fields: existing == nil ? [
                Prompt.Field(placeholder: "Username", text: login.username),
                Prompt.Field(placeholder: "Password", text: login.password, secure: true),
            ] : [],
            checkbox: existing == nil ? "Never for this site" : nil
        )
        pendingLoginShowing = true
        defer { pendingLoginShowing = false }
        guard let result = await askForPage(prompt) else { return }
        if result.confirmed {
            let username = existing == nil ? (result.fields.first ?? login.username).trimmed : login.username
            let password = existing == nil ? (result.fields.last ?? login.password) : login.password
            guard !password.isEmpty else { return }
            store.save(origin: login.origin, username: username, password: password, profile: login.profile)
            browser?.show(Toast(symbol: "key.fill", text: existing == nil ? "Password saved" : "Password updated"))
        } else if result.checked {
            store.neverSave(login.origin)
        }
    }

    /// The suggestion list's keys, while it is up and the page has the keyboard: ↓ / ↑ pick a
    /// row, Return fills it, Esc closes the list. Returns whether the key was used.
    func handlePasswordSuggestionKey(_ event: NSEvent) -> Bool {
        guard var suggestions = passwordSuggestions else { return false }
        switch event.keyCode {
        case 125, 126: // ↓ ↑
            let step = event.keyCode == 125 ? 1 : -1
            let count = suggestions.count
            let next = ((suggestions.highlighted ?? (step > 0 ? -1 : count)) + step + count) % count
            suggestions.highlighted = next
            passwordSuggestions = suggestions
            return true
        case 36, 76: // Return
            guard let index = suggestions.highlighted else { return false }
            if index < suggestions.logins.count {
                PasswordAutofill.fill(suggestions, login: suggestions.logins[index], newPassword: nil, in: self)
            } else {
                PasswordAutofill.fill(suggestions, login: nil, newPassword: suggestions.strongPassword, in: self)
            }
            return true
        case 53: // Esc
            passwordSuggestions = nil
            return true
        case 48: // Tab moves on to the next field; the list goes.
            passwordSuggestions = nil
            return false
        default:
            return false
        }
    }
}

// MARK: - List

/// The saved logins for the focused field, under it (or at the top of the page for a field
/// inside a frame), as Safari shows them.
struct PasswordSuggestionList: View {
    @Environment(BrowserState.self) private var state
    @Environment(\.accent) private var accent
    let tab: Tab
    let suggestions: PasswordSuggestions

    /// The pointer is over the list: a click on it is coming, so the page losing the keyboard
    /// doesn't close it.
    static var pointerInside = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.logins.enumerated()), id: \.element.id) { index, login in
                row(index: index, symbol: "key.fill", title: login.username.isEmpty ? "No username" : login.username,
                    detail: login.origin == suggestions.origin ? "••••••••" : login.displayName) {
                    PasswordAutofill.fill(suggestions, login: login, newPassword: nil, in: tab)
                }
            }
            if let strong = suggestions.strongPassword {
                row(index: suggestions.logins.count, symbol: "key.viewfinder", title: "Use Strong Password", detail: strong) {
                    PasswordAutofill.fill(suggestions, login: nil, newPassword: strong, in: tab)
                }
            }
            Divider().padding(.vertical, 2)
            Button {
                tab.passwordSuggestions = nil
                AppDelegate.shared?.showSettings(tab: .passwords)
            } label: {
                Text("Manage Passwords…")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .frame(width: 280)
        .background(
            ZStack {
                VisualEffect(material: .menu, blending: .withinWindow)
                Color(nsColor: state.currentTint).opacity(0.35)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
        .modifier(CardShadow(cornerRadius: 11, opacity: 0.3, radius: 14, y: 6, hollow: true))
        .environment(\.colorScheme, AppSettings.shared.chromeScheme(for: state.currentTint))
        .onHover { Self.pointerInside = $0 }
        .onDisappear { Self.pointerInside = false }
    }

    private func row(index: Int, symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        let highlighted = suggestions.highlighted == index
        return Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(highlighted ? .white : accent)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? .white.opacity(0.22) : accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 11, design: detail.hasPrefix("••") ? .default : .monospaced))
                        .foregroundStyle(highlighted ? .white.opacity(0.75) : .primary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if highlighted { KeyHint("↩") }
            }
            .foregroundStyle(highlighted ? .white : .primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
