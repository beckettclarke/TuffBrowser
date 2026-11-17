# Tuff — Extension & App TODO list

Generated from a full-source audit (every Swift file + the compat shim + the install pipeline),
cross-checked against the WebKit SDK headers (`WKWebExtensionTab.h`, `WKWebExtensionWindow.h`,
`WKWebExtensionControllerDelegate.h`, `WKWebExtensionPermission.h`) and the WebKit binary on this
Mac to confirm which APIs the engine actually implements.

**Goal: extensions should have FULL functionality.** This list is everything standing in the way,
plus general bugs found along the way.

## How to use this list (other agents)

- Pick an unchecked item, do it, then tick it `- [x]` and add your initials/date if you like.
- Don't duplicate work: check the box and the surrounding section before starting.
- **Follow `AGENTS.md` / `CLAUDE.md`:** custom `Prompt` cards only (never `NSAlert`), keep the
  window opaque unless Glass, no `.shadow` on web-view/backdrop containers, don't re-enable
  WebKit process prewarming/cache, don't grant user-installed fonts to pages.
- Test with the debug harness: `TUFF_DATA_DIR=… TUFF_DEBUG_SCRIPT="…" Tuff.app/Contents/MacOS/Tuff`
  (see `Support/DebugHooks.swift`). `TUFF_EXT_DEBUG=1` forwards an extension's background console
  and uncaught errors to the log — the fastest way to see why an extension misbehaves.
- Priority tags: **[P0]** broken-but-supported (easy, high value) · **[P1]** high-value missing
  features · **[P2]** feasible missing features · **[P3]** minor/edge · **[BUG]** correctness ·
  **[POLICY]** violates project rules · **[VERIFY]** confirm before acting · **[WONTFIX]** engine
  limitation, document only.

---

## A. [P0] APIs WebKit supports but Tuff's host adapter doesn't wire up

The engine implements the JS API; the call fails only because the `WKWebExtension*` protocol
method is missing in `Extensions/ExtensionBridge.swift`. These are the easiest, highest-value fixes.

### Tab adapter (`extension Tab: WKWebExtensionTab`)
- [x] **[P0]** Implement `takeSnapshot(using:for:completionHandler:)` → fixes `tabs.captureVisibleTab()`.
      Done: forwards to `WKWebView.takeSnapshot(with:)` using the passed `WKSnapshotConfiguration`.
- [x] **[P0]** Implement `detectWebpageLocale(for:completionHandler:)` → fixes `tabs.detectLanguage()`.
      Done: WebKit has no public detector, so it reads a slice of `document.body.innerText`, runs
      `NLLanguageRecognizer`, and falls back to the page's declared `lang`.
- [x] **[P0]** Implement `pendingURL(for:)` → returns the in-flight URL so `tabs.get`/`query` expose `pendingUrl`.
      Done: new `Tab.pendingURL`, set on load / main-frame navigation, cleared on commit / fail / teardown.
- [x] **[P0]** Implement `parentTab(for:)` + `setParentTab(_:for:completionHandler:)` → fixes `openerTabId`
      and `tabs.create({openerTabId})`. Done: new weak `Tab.openerTab`, set in `BrowserState.newTab(after:)`.
- [x] **[P0]** Implement `setSelected(_:for:completionHandler:)` → `tabs.update({active})` / `tabs.highlight`
      selection path. Done: selects via `browser.select(self)` when `selected` is true (deselect is a no-op).
- [ ] **[P3]** Implement reader-mode trio `isReaderModeAvailable` / `isReaderModeActive` /
      `setReaderModeActive` (WebKit reader-mode tab APIs). Low demand; optional.

### Window adapter (`BrowserWindowAdapter: WKWebExtensionWindow`)
- [x] **[P0]** Implement `setWindowState(_:for:completionHandler:)` → `windows.update({state})`
      (minimized / maximized / fullscreen / normal). Done: maps to miniaturize / zoom / toggleFullScreen.
- [x] **[P0]** Implement `setFrame(_:for:completionHandler:)` → `windows.update({left,top,width,height})`.
      Done: uses the same screen-coordinate convention as `frame(for:)` so a get/set round-trips.
- [x] **[P0]** Implement `close(for:completionHandler:)` → `windows.remove()`. Done: single-window model —
      `performClose` on the browser window; session kept, window returns from the Dock, no tabs destroyed.
- [ ] **[P2]** `openNewWindowUsing` (ExtensionManager.swift:955) ignores `windowType`, incognito, and
      moving existing tabs (`configuration.tabs`). At least honour moving existing tabs; document the rest.

> **Status: all 8 P0 items implemented and Debug build verified (`make build` → BUILD SUCCEEDED).**
> Files touched: `Extensions/ExtensionBridge.swift`, `Model/Tab.swift`, `Model/BrowserState.swift`,
> `Web/Tab+Web.swift`. Remaining warnings are pre-existing and unrelated.

---

## B. [P1] Inert namespaces Tuff can implement with machinery it already has

`ExtensionCompat.swift`'s `missing` array installs no-op proxies (methods → `undefined`, events never
fire). WebKit genuinely lacks these (verified). Each below is currently a silent no-op but Tuff has the
underlying data/capability to make it real. Implement natively, then remove the name from the shim's
`missing` list (or have the shim defer to a real implementation).

- [x] **[P1]** `chrome.history` → wired to `HistoryStore`: `search`, `getVisits`, `addUrl`, `deleteUrl`,
      `deleteRange`, `deleteAll` implemented via the native bridge. `getVisits` reports the last visit
      (the store keeps aggregates, not a per-visit log). **Events (`onVisited`/`onVisitRemoved`/
      `onTitleChanged`) still inert** — need the event-push mechanism (below).
- [x] **[P1]** `chrome.downloads` → `ExtensionDownloads.swift` + `DownloadManager`: `download` (hidden web
      view on the profile store → `WKDownload`), `search`, `cancel`, `erase`, `open`, `show` implemented.
      **`pause`/`resume` report an error (WKDownload has neither); `filename`/`saveAs`/`conflictAction` not
      honoured yet; events inert.** Added `chromeID`/`url`/byte counts to `DownloadItem` (additive, UI-safe).
- [x] **[P1]** `chrome.notifications` → `UNUserNotificationCenter` (`ExtensionNotifications.swift`):
      `create` (title / message / silent), `clear`, `getAll`, `getPermissionLevel` implemented; prompts
      for system permission on first use. **`update`, `iconUrl` attachments, and click/close events
      still pending** (events need the push mechanism).
- [x] **[P1]** `chrome.identity` → `ExtensionIdentity.swift`: `getRedirectURL` (computed synchronously in
      the shim) + `launchWebAuthFlow` (presented web view intercepting the `chromiumapp.org` redirect)
      implemented — **unblocks OAuth sign-in**. Used a WKWebView rather than ASWebAuthenticationSession
      because the `https://<id>.chromiumapp.org` redirect can't be a callbackURLScheme. `getAuthToken` /
      `removeCachedAuthToken` (Chrome-account) remain unsupported; `onSignInChanged` inert.
- [x] **[P1]** `chrome.offscreen` (MV3) → `ExtensionOffscreen.swift`: `createDocument`, `closeDocument`,
      `hasDocument` + `Reason` enum implemented as a hidden extension web view (SocketRelay pattern);
      WebKit routes its runtime messaging. One per extension; cleaned up on unload. **Verify at runtime
      that messaging reaches the worker.**
- [x] **[P1]** `chrome.management` → wired to `ExtensionManager.records`: `getAll`, `get`, `getSelf`,
      `getPermissionWarningsById`, `setEnabled` implemented. **`uninstallSelf` + events still pending**
      (uninstall needs a confirm card; events need the push mechanism).
- [x] **[P1]** `chrome.sessions` → wired to `BrowserState.closedTabs`: `getRecentlyClosed`, `restore`
      (by id, or most recent when omitted), `getDevices` (empty — no sync) implemented. Added stable
      `id` + `closedAt` to `ClosedTab` (optional, so old sessions still decode). **`onChanged` still inert.**
- [x] **[P1]** `chrome.topSites` → `get` implemented, derived from `HistoryStore` visit counts.
- [x] **[P1]** `chrome.browsingData` → `remove`, `removeCache`, `removeCookies`, `removeLocalStorage`,
      `removeHistory`, `settings` implemented (async, across all profile stores). `removeDownloads` /
      `removeFormData` / `removePasswords` pending (no clean WebKit data-type mapping).
- [ ] **[P1]** `chrome.tabGroups` → map to Tuff folders (Model/Folder.swift): `get`, `query`, `update`,
      `move`, `onCreated`/`onUpdated`/`onMoved`/`onRemoved`. Also `tabs.group`/`ungroup`.
- [ ] **[P1]** Firefox `browser.contextualIdentities` → map to Tuff profiles (Model/Profile.swift):
      `query`, `get`, `create`, `update`, `remove`, `onCreated`/`onUpdated`/`onRemoved`.

> **Bridge built (this batch):** `Extensions/ExtensionAPIs.swift` (`ExtensionAPIBridge`) generalizes the
> side-panel bridge: the shim calls `tabs.create({url:'tuff-api://<ns>/<method>/?d=<json>'})`, Tuff answers
> with JSON carried in the call's error. It is **async-capable**. `topSites`, `history`, `browsingData`,
> `management`, `sessions`, `notifications`, `offscreen`, `identity`, `downloads`, `system`, `power`,
> `idle`, `tts`, `search` now route through it (removed from the shim's `missing` list). **Debug build + runtime smoke
> test verified** — a test extension exercised all of these through the bridge and every call returned
> correct data (offscreen create→has→close lifecycle, real cpu/memory/storage values, power assertion,
> idle state all confirmed).
>
> **Event push — DONE:** since `WKWebExtensionContext` has no public background-script-evaluation API,
> events are delivered via a per-extension relay page that Tuff scripts to call `chrome.runtime.sendMessage`
> (a wake event for the MV3 worker); the shim dispatches to real listeners. Verified end-to-end. See the
> event-push item below for which events are wired vs. remaining.
- [x] **[P1]** Event-push mechanism → `ExtensionEventPush.swift`: a per-extension relay page that Tuff
      scripts to call `chrome.runtime.sendMessage` (a wake event for the MV3 worker); the shim dispatches to
      real listeners. Subscription model, so only extensions that listen get a relay / are woken.
      **Runtime-verified: `history.onVisited` + `history.onVisitRemoved` fire end-to-end and wake the worker.**
      Wired: `history.onVisited`/`onVisitRemoved`/`onTitleChanged`, `downloads.onCreated`/`onChanged`/`onErased`,
      `notifications.onClicked`/`onClosed`, `sessions.onChanged`, `management.onInstalled`/`onUninstalled`/
      `onEnabled`/`onDisabled`, `tts.onEvent`, `idle.onStateChanged`.
      Remaining: `notifications.onButtonClicked` (needs notification buttons), `identity.onSignInChanged`
      (Chrome-account, N/A).

## C. [P2] Other feasible inert namespaces

- [x] **[P2]** `chrome.idle` → `ExtensionSystem.swift`: `queryState` (CGEventSource HID idle time),
      `setDetectionInterval`, and `onStateChanged` (timer polls and pushes on change) implemented.
- [ ] **[P2]** `chrome.clipboard` (Firefox) + `clipboardRead`/`clipboardWrite` → `NSPasteboard`.
- [ ] **[P2]** `chrome.privacy` → map to `AppSettings.privacy` (network/webRTC/cookies etc. as feasible).
- [ ] **[P2]** `chrome.contentSettings` → map to `SitePermissions` (camera/mic/cookies/JS/images…).
- [ ] **[P2]** Firefox `browser.browserSettings` → map to `AppSettings` (allowPopups, cookies, JS, etc.).
- [ ] **[P2]** Firefox `browser.theme` → map to Tuff `Theme` (getCurrent, update, reset, onUpdated).
- [ ] **[P2]** Firefox `browser.find` → wire to the find bar (RootView.swift `FindBar`): `find`, `highlightResults`, `removeHighlighting`.
- [x] **[P2]** `chrome.search` → `query` implemented (opens the configured engine; CURRENT_TAB / NEW_TAB).
      Firefox `browser.search.get` pending.
- [ ] **[P2]** `chrome.omnibox` → command-bar keyword integration: `setDefaultSuggestion`, `onInputStarted/Changed/Entered/Cancelled`.
- [x] **[P2]** `chrome.tts` → `ExtensionTTS.swift` (AVSpeechSynthesizer): `speak`, `stop`, `pause`, `resume`,
      `getVoices`, `isSpeaking` implemented (180 voices returned in test); `onEvent` (start/end/interrupted/
      paused/resumed) pushed via the event mechanism.
- [x] **[P2]** `chrome.system.cpu` / `system.memory` / `system.storage` → `ExtensionSystem.swift`: `getInfo`
      for all three (processor count / arch / model, physical + available memory, boot-volume capacity).
- [x] **[P2]** `chrome.power` → `ExtensionSystem.swift`: `requestKeepAwake` (system / display) +
      `releaseKeepAwake`, per-extension IOKit power assertions.
- [x] **[P2]** `chrome.userScripts` (MV3) → `WKUserScript` registration: `register`, `unregister`, `getScripts`, `update`
      (`ExtensionContentScripts.swift`). Still missing: `configureWorld` messaging / `runtime.onUserScriptMessage`, `execute`.
- [x] **[P2]** Firefox `browser.contentScripts` → dynamic content-script registration: `register`, `unregister`
      (also Firefox MV2 `userScripts.register`). Isolated-world scripts get a world per extension without extension APIs.
- [ ] **[P2]** `chrome.proxy` → system/proxy config: `settings`, `onProxyError`. (Scope carefully; may be partial.)
- [ ] **[P2]** `chrome.fontSettings` → font prefs: `getFont`, `setFont`, `clearFont`, `getFontList`, `onFontChanged`.

## D. [P3] Hard / niche inert namespaces (list for completeness; likely leave as no-ops)

- [ ] **[P3]** `gcm`, `instanceID` (push messaging) — needs a push service; probably WONTFIX.
- [ ] **[P3]** `debugger` (attach debugger protocol) — large; probably WONTFIX.
- [ ] **[P3]** `pageCapture` (save as MHTML) — WebKit has no MHTML; probably WONTFIX.
- [ ] **[P3]** `readingList`, `enterprise.*`, `loginState`, `documentScan`, `printing`, `vpnProvider`,
      `wallpaper`, `certificateProvider`, `platformKeys`, `webAuthenticationProxy` — ChromeOS/enterprise; WONTFIX.
- [ ] **[P3]** Firefox `dns`, `captivePortal`, `networkStatus`, `pkcs11` — niche; WONTFIX unless requested.
- [ ] **[P3]** `ttsEngine` (provide TTS voices) — niche; WONTFIX.

---

## E. [P3] Missing methods/events that throw or never fire

### Undefined → calling throws (NOT covered by the shim)
- [ ] **[P3]** `declarativeNetRequest.testMatchOutcome` — absent from WebKit, not stubbed. Add a shim
      stand-in (or implement against the DNR engine) so rule-tester extensions don't crash.
- [ ] **[P3]** `extension.getExtensionTabs` — absent, not stubbed (legacy). Add inert stand-in.
- [ ] **[P3]** `declarativeNetRequest` constants (`MAX_NUMBER_OF_DYNAMIC_RULES`, `MAX_NUMBER_OF_REGEX_RULES`,
      `MAX_NUMBER_OF_SESSION_RULES`, …) — define sensible values in the shim.

### Inert events (WebKit lacks them; shim stand-ins never fire)
- [ ] **[P2]** `webNavigation.onHistoryStateUpdated` + `onReferenceFragmentUpdated` — SPA / hash navigation.
      Drive from `WKNavigationDelegate` (same-document navigations) in Tab+Web.swift.
- [ ] **[P2]** `webNavigation.onCreatedNavigationTarget` — window.open / target=_blank. Drive from
      `createWebViewWith` (Tab+Web.swift) / `openNewTabUsing`.
- [ ] **[P3]** `webNavigation.onTabReplaced` — rare; inert acceptable.
- [ ] **[P3]** `tabs.onZoomChange` — fire from `Tab.setZoom` (Tab.swift:380).
- [ ] **[P3]** `windows.onBoundsChanged` — fire from `windowDidResize` (BrowserWindowController.swift).
- [ ] **[P3]** `runtime.onSuspendCanceled` / `onUpdateAvailable` / `onRestartRequired` /
      `onBrowserUpdateAvailable` / `onUserScriptMessage` / `onUserScriptConnect` / `onConnectNative` — mostly
      lifecycle/debug; wire the ones that become relevant (e.g. onUpdateAvailable once auto-update lands).
- [ ] **[P3]** `webRequest.onActionIgnored`, `action.onUserSettingsChanged`, `commands.onChanged`,
      `declarativeNetRequest.onRuleMatchedDebug`, `extension.onRequest`/`onRequestExternal` — minor/debug.

---

## F. [BUG] Extension-code correctness

- [x] **[BUG]** **Mute lost on sleep/wake** — `Tab.wake()` (Tab.swift:102) re-applies `pageZoom` but not
      `isMuted`. Re-apply mute on wake and after navigation (`_setPageMuted:` is per-page). Also
      `setMuted` (Tab.swift:386) sets `isMuted` then returns early when `webView == nil` without firing
      `tabDidChange` — keep state consistent.
- [ ] **[BUG]** **No extension auto-update** — `updateFromStore` (ExtensionManager.swift:603) always
      re-downloads with no version check. Add version comparison + a periodic update check; fire
      `runtime.onUpdateAvailable` when relevant.
- [ ] **[BUG]** `chromeDownloadURL` (ExtensionManager.swift:424) hardcodes `prodversion=140.0.0.0` and
      `arch=arm64`. Use a current prodversion and the host's real arch; honour `minimum_chrome_version`.
- [ ] **[BUG]** `.zip` Firefox add-ons misdetected — `performInstall` (ExtensionManager.swift:534) keys
      off `.xpi` only. Sniff the manifest (`browser_specific_settings.gecko`) to pick the source/origin.
- [ ] **[BUG]** Shim skips HTML pages with no `<script>` tag — `ExtensionCompat.patch`
      (ExtensionCompat.swift:176). Inject before `</head>`/`<body>` as a fallback so every page gets it.
- [ ] **[BUG]** `SidePanelManager.open` (SidePanels.swift:154) guard `url(...) != nil || tabOptions[id]?.isEmpty == false`
      can open a panel with no resolvable URL on the current tab. Tighten the condition.
- [ ] **[BUG]** `finishInstall` (ExtensionManager.swift:595) hardcoded 800 ms teardown sleep — replace with
      a deterministic wait (completion/callback) to avoid the race on slow machines.
- [ ] **[BUG]** Native messaging (NativeMessaging.swift): `send()` silently drops when the process isn't
      running / JSON invalid — surface an error to the extension. Capture stderr for diagnostics.
      Add system-wide Chromium dir to `searchDirectories`.
- [ ] **[BUG]** `handleKeyEvent` (ExtensionManager.swift:847): handle `_execute_page_action`; define
      deterministic precedence when multiple extensions register the same shortcut.
- [x] **[BUG]** `BrowserState.close` for pinned/favorites (BrowserState.swift:219) resets to `homeURL`
      without notifying extensions — fire a URL change so `tabs.onUpdated` isn't stale.
- [ ] **[BUG]** `SocketRelay` (ExtensionManager.swift:907) mutates the extension's *shared* configuration
      preferences (`inactiveSchedulingPolicy`) — copy the configuration so other web views aren't affected.
- [ ] **[BUG]** Fragile shim markers — module-worker re-patch (`refresh`, ExtensionCompat.swift:214)
      depends on the first 40 bytes + a unique `})();` line. Make the boundary robust (explicit sentinel).

---

## G. [BUG] General app correctness

- [ ] **[BUG]** Latent crash — `BrowserState.currentSpace` (BrowserState.swift:81) and `profile(for:)` (:86)
      index `[0]` without an empty guard. Add safe fallbacks.
- [x] **[BUG]** `closeIdleTabs` (BrowserState.swift:837) doesn't check `tab.isLoading` (unlike
      `sleepIdleTabs`) — a stuck loading tab can be auto-closed. Add the check.
- [x] **[BUG]** `DownloadManager.uniqueDestination` (Stores.swift:273) check-then-use race for concurrent
      same-name downloads; empty filename yields `" 2"`, `" 3"`. Reserve atomically; handle empty names.
- [ ] **[BUG]** `FaviconStore.fetchIcon` (Stores.swift:148) uses a separate ephemeral `URLSession`, not the
      tab's profile store — auth-gated favicons fail and per-profile isolation is bypassed. Fetch in-context.
- [x] **[BUG]** `WebEngine` sets `developerExtrasEnabled` via KVC without a `responds` guard
      (WebEngine.swift:90, :131) — guard it like the other private prefs to avoid `NSUndefinedKeyException`.
- [ ] **[BUG]** `BrowserState.newTab` before restore (BrowserState.swift:172) returns an orphaned `Tab`
      (`browser == nil`, in no space). Queue properly or document the contract.
- [ ] **[BUG]** `Tab.handleLoadFailure` (Tab+Web.swift:135) loads a simulated error page even in extension
      web views where it may not render. Skip/branch for extension pages.

---

## H. [POLICY] AGENTS.md violations (native dialogs)

- [x] **[POLICY]** `UpdateController.checkForUpdates` (AppDelegate.swift:284) shows a native `NSAlert`
      ("Updates aren't set up for this build") — user-visible via the menu. Replace with a `Prompt` card.
- [ ] **[POLICY]** `PromptPresenter.fallbackAlert` (Prompt.swift:126) uses `NSAlert` when no host window
      exists. Rare, but still user-visible — replace or justify per the "developer-only" exception.

---

## I. [VERIFY] Confirm before acting

- [ ] **[VERIFY]** **`sidePanel` bypass risk** — the shim installs Tuff's bridge only `if absent(root,'sidePanel')`.
      The WebKit binary contains `sidePanel`/`getLayout`/`setLayout` strings (possibly generic false positives).
      At runtime, check whether WebKit exposes any `sidePanel` object; if it does, Tuff's working bridge is
      bypassed for WebKit's partial one. If so, force Tuff's implementation.
- [ ] **[VERIFY]** **`devtools_page` / `chrome.devtools.*`** — no host handling exists; binary has
      `inspectedWindow`/`devtools_page` but lacks `getResources`/`setContent`. Confirm whether React/Redux/Vue
      DevTools can work at all; if not, document as unsupported (see J).
- [ ] **[VERIFY]** Re-confirm any "inert" namespace before implementing it — generic binary strings
      (`notifications`, `downloads`, `cpu`, `search`, …) false-positive; trust distinctive camelCase API
      identifiers and a runtime `typeof chrome.X` check in an extension page.

---

## J. [WONTFIX] Fundamental WebKit limitations (document, don't fight)

- [ ] **[WONTFIX]** `webRequestBlocking` — WebKit reports requests to extensions only after they are sent, and has
      no hook to hold one (navigation policy covers frames only; a proxy sees only HTTPS hostnames; taking over
      http(s) with a scheme handler would mean Tuff doing all networking). Covered instead by Tuff's built-in
      blocker (`Web/ContentBlocker.swift`). Not carried over: `redirect=`, `removeparam`, header/HTML filtering, `csp=`.
- [x] Private browsing: Incognito windows (⇧⌘N). Extensions don't run in them (`isPrivate` stays false for the main window).
- [ ] **[WONTFIX]** No Widevine (FairPlay only) — document.
- [ ] **[WONTFIX]** Single browser window — `windows.*` semantics are inherently limited; document what
      "window" means in Tuff (see A window-adapter items for the feasible subset).

---

## K. [FEATURE] Missing browser features (2026-11-16 audit)

Things Safari / Chrome / Arc users expect that Tuff doesn't have yet. The bugs and security
problems from the same audit are fixed (see BUGS.md).

### Calls, media and full screen
- [ ] **[P1]** **"{site} is in full screen" banner.** When a page goes full screen (a YouTube or
      Netflix video), show a small card at the top: the site's name and "Press Esc to exit full
      screen", fading after a few seconds, as Chrome and Safari do. Drive it from KVO on
      `WKWebView.fullscreenState`; reuse the toast/card look (no `.shadow`, see AGENTS.md).
- [ ] **[P1]** **Screen sharing (`getDisplayMedia`).** Nothing handles it, so "Present" in Meet,
      Zoom and Teams fails. Needs WebKit's display-capture permission delegate (private
      `_webView:requestDisplayCapturePermissionForOrigin:…` and the screen-capture preference)
      plus a `SitePermissionKind.screen` and a card.
- [ ] **[P1]** **Camera / microphone in-use indicator** on the tab row (and horizontal tab), with a
      click to stop: observe `cameraCaptureState` / `microphoneCaptureState`, stop with
      `setCameraCaptureState(.none)` / `setMicrophoneCaptureState(.none)`.

### Sign-in and passwords
- [ ] **[P1]** **Passkeys / WebAuthn.** Third-party WKWebView browsers need Apple's
      `com.apple.developer.web-browser.public-key-credential` entitlement (Developer ID + a request
      to Apple). Without it passkeys and security keys fail on most sites. Test on webauthn.io.
- [ ] **[P1]** **Password saving and autofill.** Nothing built in (HTTP sign-in is `.forSession`
      only); today it's extensions (1Password, Bitwarden). Either a Keychain-backed store with a
      save card and fill-on-focus, or document the extension route in onboarding.

### Privacy and site controls
- [ ] **[P1]** **"Pop-up blocked" indicator.** With Block pop-ups on, blocked `window.open`s vanish
      silently. Show an icon in the address pill with "Allow pop-ups from {site}" (per-site
      setting already exists in `SiteSettings`).
- [ ] **[P2]** **Per-site website data.** Remove one site's cookies and storage (Settings → Websites
      and the page menu), and clear by time range (last hour / today / all). Today it's "Remove
      All" only.
- [ ] **[P2]** **List "open in app" answers** ("Always allow {site} to open {App} links",
      `ExternalAppLinks`) in Settings → Websites, each removable. Today only "Forget All" clears them.
- [ ] **[P2]** **HTTPS-first mode:** try https for every site, with a warning page before falling
      back to http. `upgradeKnownHostsToHTTPS` only covers sites WebKit knows support it.
- [ ] **[P3]** Web Push (notifications only arrive while Tuff is running).

### History, search and tabs
- [ ] **[P2]** **History keeps one entry per page** (last visit only), so a page seen yesterday and
      today shows under today only. Keep a per-visit log.
- [ ] **[P2]** **History per profile.** School's command bar suggests Home's history today.
- [ ] **[P2]** History menu: **Recently Closed** and **recent pages** submenus.
- [ ] **[P2]** Command bar **zero state** (⌘T on an empty field: top sites, recent tabs) and
      **Paste and Go** in the address pill's menu.
- [ ] **[P2]** **Translate page** (Apple's Translation framework).
- [ ] **[P3]** Per-site user agent; ⌥-click a link to download it; text-only zoom.
- [ ] **[P3]** A quick "save for later" / bookmarks manager (favourites and pinned tabs cover most of it).

### Quality
- [ ] **[P2]** **Accessibility.** One `accessibilityLabel` in the whole UI; the 42 `IconButton`s
      only have tooltips, so VoiceOver reads symbol names. Label icon buttons, tab rows, tiles.
- [ ] **[P2]** **Unit tests.** No test target. Start with `BrowserState.resolve`, `Tab.samePage`,
      `Tab.zoomStep`, `AdvancedSettings.currentMajorVersion`, `SitePermissions.decision`.
- [ ] **[P3]** Localization (no strings are localizable yet).

---

### Suggested order of attack
1. **Section A** (P0 host-adapter methods) — small, self-contained, immediately fixes real APIs.
2. **Section F mute bug + Section H policy** — quick correctness/rule wins.
3. **Section B** (P1 namespaces) — biggest functionality payoff; history/downloads/notifications/identity/offscreen first.
4. **Section E** webNavigation SPA events, then **C**, then the rest.
5. Keep **I (verify)** ahead of any sidePanel/devtools work.