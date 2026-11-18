# Tuff — Extension & App TODO list

> **App updates: none built in.** Sparkle was removed on 2026-11-17 (it was never configured, so it
> never updated anything, and it added a framework plus XPC helpers to the bundle). The "Check for
> Updates…" menu item and About button went with it. If updates are wanted later, write a small
> in-house updater (signed appcast or GitHub Releases check → download → verify signature → swap
> and relaunch, with `Prompt` cards).

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
- [x] **[P3]** Implement reader-mode trio `isReaderModeAvailable` / `isReaderModeActive` /
      `setReaderModeActive` (WebKit reader-mode tab APIs). Low demand; optional.
      Done (2026-11-17): on Tuff's reader mode (`Reader/Reader.swift`), which now also reports `.readerMode` changes.
      Runtime-verified: `tabs.get` gives `isArticle: true` on example.com.

### Window adapter (`BrowserWindowAdapter: WKWebExtensionWindow`)
- [x] **[P0]** Implement `setWindowState(_:for:completionHandler:)` → `windows.update({state})`
      (minimized / maximized / fullscreen / normal). Done: maps to miniaturize / zoom / toggleFullScreen.
- [x] **[P0]** Implement `setFrame(_:for:completionHandler:)` → `windows.update({left,top,width,height})`.
      Done: uses the same screen-coordinate convention as `frame(for:)` so a get/set round-trips.
- [x] **[P0]** Implement `close(for:completionHandler:)` → `windows.remove()`. Done: single-window model —
      `performClose` on the browser window; session kept, window returns from the Dock, no tabs destroyed.
- [x] **[P2]** `openNewWindowUsing` (ExtensionManager.swift:955) ignores `windowType`, incognito, and
      moving existing tabs (`configuration.tabs`). At least honour moving existing tabs; document the rest.
      Done (2026-11-17): `incognito: true` opens a real Incognito window with the URLs (the extension gets no
      window back, since extensions don't run there). Otherwise the "new window" is the main one: its URLs
      open side by side, the first (or the first tab it was asked to move) is brought forward if `focused`,
      and nothing is selected if `focused: false`. Popup windows open as tabs, and `state` / size are
      ignored (they would resize the user's only window). Runtime-verified.

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
      `deleteRange`, `deleteAll` implemented via the native bridge. `getVisits` reports every retained
      visit, scoped to the current profile. Events (`onVisited`/`onVisitRemoved`/`onTitleChanged`) use
      native event push.
- [x] **[P1]** `chrome.downloads` → `ExtensionDownloads.swift` + `DownloadManager`: `download` (hidden web
      view on the profile store → `WKDownload`), `search`, `cancel`, `erase`, `open`, `show` implemented.
      `pause`/`resume` use `DownloadManager` (WebKit resume data and multi-connection ranges), and
      created/changed/erased events use native event push. 2026-11-18: `filename` (including safe relative
      subfolders), `saveAs`, and `uniquify` / `overwrite` / `prompt` conflict handling work in both download
      engines; a real extension download completed in the requested subfolder.
- [x] **[P1]** `chrome.notifications` → `UNUserNotificationCenter` (`ExtensionNotifications.swift`):
      `create`, `clear`, `getAll`, `getPermissionLevel`, `update` implemented; IDs are isolated per extension.
      Prompts for system permission on first use. 2026-11-18: `iconUrl` loads extension / web images, up to
      two buttons use native actions, and `onButtonClicked` reports the index. Delivery wasn't runtime-tested
      because macOS denied notification permission in the throwaway test profile.
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
      `getPermissionWarningsById`, `setEnabled`, `uninstallSelf` and events implemented. `uninstallSelf`
      uses the destructive confirmation card; runtime-verified 2026-11-18.
- [x] **[P1]** `chrome.sessions` → wired to `BrowserState.closedTabs`: `getRecentlyClosed`, `restore`
      (by id, or most recent when omitted), `getDevices` (empty — no sync) implemented. Added stable
      `id` + `closedAt` to `ClosedTab` (optional, so old sessions still decode). `onChanged` fires on close,
      restore and clear (event push).
- [x] **[P1]** `chrome.topSites` → `get` implemented, derived from `HistoryStore` visit counts.
- [x] **[P1]** `chrome.browsingData` → `remove`, `removeCache`, `removeCookies`, `removeLocalStorage`,
      `removeHistory`, `settings` implemented (async, across all profile stores).
      2026-11-17: `downloads` clears the (non-Incognito) downloads list since `since`, files kept, as in
      Chrome. `formData` / `passwords` succeed with nothing to do: Tuff saves neither.
- [x] **[P1]** `chrome.tabGroups` → map to Tuff folders (Model/Folder.swift): `get`, `query`, `update`,
      `move`, `onCreated`/`onUpdated`/`onMoved`/`onRemoved`. Also `tabs.group`/`ungroup`.
      Done (2026-11-17): `Extensions/ExtensionGroups.swift`. Grouping pins a tab into the folder; ungrouping
      returns it to the space's regular tabs; a folder made by `tabs.group` goes away with its last tab
      (the user's own folders never do). Group ids are per session; folders have no colour, so a colour an
      extension sets lasts the session. Events come from `BrowserState` (the user's folder changes fire them
      too). Extensions that declare `tabGroups` get `groupId` on `tabs.query` / `tabs.get` and can query by it.
      Runtime-verified (group, get, update, query by groupId, ungroup, onCreated/onUpdated/onRemoved).
- [x] **[P1]** Firefox `browser.contextualIdentities` → map to Tuff profiles (Model/Profile.swift):
      `query`, `get`, `create`, `update`, `remove`, `onCreated`/`onUpdated`/`onRemoved`.
      Done (2026-11-17): `cookieStoreId` is `firefox-container-<profile id>`; icons map to SF Symbols, colours
      are derived from the profile's first space (or the one an extension set, for the session). `remove`
      deletes the profile only after a destructive `Prompt` card. Extensions that declare
      `contextualIdentities` get `cookieStoreId` on tabs, can query by it, and `tabs.create({cookieStoreId})`
      opens the tab in a space of that profile (an error if the profile has no space yet). Runtime-verified.

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
      `onEnabled`/`onDisabled`, `tts.onEvent`, `idle.onStateChanged`, `notifications.onButtonClicked`.
      Remaining: `identity.onSignInChanged` (Chrome-account, N/A).

## C. [P2] Other feasible inert namespaces

- [x] **[P2]** `chrome.idle` → `ExtensionSystem.swift`: `queryState` (CGEventSource HID idle time),
      `setDetectionInterval`, and `onStateChanged` (timer polls and pushes on change) implemented.
- [x] **[P2]** `chrome.clipboard` (Firefox) + `clipboardRead`/`clipboardWrite` → `NSPasteboard`.
      Done (2026-11-17): `setImageData` (png / jpeg) writes to the pasteboard. The image travels in the bridge
      URL, so very large images may not fit. Runtime-verified.
- [x] **[P2]** `chrome.privacy` → map to `AppSettings.privacy` (network/webRTC/cookies etc. as feasible).
      Done (2026-11-17): `Extensions/ExtensionSettings.swift` (one `ChromeSetting` model for privacy, proxy,
      browserSettings and fonts, with level of control, `clear`, `onChange`, and the old value put back when
      the extension is turned off or removed). Controllable: `services.safeBrowsingEnabled`,
      `services.searchSuggestEnabled`, `websites.thirdPartyCookiesAllowed`, Firefox `websites.cookieConfig`.
      The rest report what WebKit does as `not_controllable`. Runtime-verified.
- [x] **[P2]** `chrome.contentSettings` → map to `SitePermissions` (camera/mic/cookies/JS/images…).
      Done (2026-11-17): `javascript` / `popups` on `SiteSettings` (per host, or every site via `<all_urls>`,
      which changes Settings → Privacy); `location` / `notifications` / `camera` / `microphone` on
      `SitePermissions` (allow / block / ask). `cookies`, `images`, etc. report Tuff's behaviour and refuse
      `set`. `clear`, and turning the extension off or removing it, takes its changes back out. Runtime-verified.
- [x] **[P2]** Firefox `browser.browserSettings` → map to `AppSettings` (allowPopups, cookies, JS, etc.).
      Done (2026-11-17): all of Firefox's keys answer with what Tuff does; `verticalTabs` is controllable.
- [x] **[P2]** Firefox `browser.theme` → map to Tuff `Theme` (getCurrent, update, reset, onUpdated).
      Done (2026-11-17): a theme's `frame` colour tints the window over the user's tint and space colours
      (never in Incognito) until `reset` or the extension is turned off; the user's theme is never changed.
      Runtime-verified.
- [x] **[P2]** Firefox `browser.find` → wire to the find bar (RootView.swift `FindBar`): `find`, `highlightResults`, `removeHighlighting`.
      Done (2026-11-17): searched in a content world of its own instead of the find bar, with `caseSensitive`,
      `entireWord`, `matchDiacritics`, `rangeData` and `rectData`; highlights use the CSS Custom Highlight API.
      Runtime-verified.
- [x] **[P2]** `chrome.search` → `query` implemented (opens the configured engine; CURRENT_TAB / NEW_TAB).
      Firefox `browser.search.get` returns the configured engine and templates; runtime-verified 2026-11-18.
- [x] **[P2]** `chrome.omnibox` → command-bar keyword integration: `setDefaultSuggestion`, `onInputStarted/Changed/Entered/Cancelled`.
      Done (2026-11-17): typing an extension's keyword and a space in the command bar turns it into a chip;
      the rest goes to `onInputChanged`, its `suggest()` results list under the field, ↩ sends
      `onInputEntered` (`newForegroundTab` from ⌘T, `currentTab` from ⌘L), and Esc / ⌫ on the chip cancels.
      Runtime-verified, including `onDeleteSuggestion`.
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
- [x] **[P2]** `chrome.proxy` → system/proxy config: `settings`, `onProxyError`. (Scope carefully; may be partial.)
      Done (2026-11-17): `fixed_servers` (HTTP / HTTPS CONNECT and SOCKS5, with `bypassList`) and `system`,
      on every website data store through `WKWebsiteDataStore.proxyConfigurations`; Firefox's
      `manual` shape too. `direct` / `none` is refused because WebKit can't bypass system proxies explicitly. `pac_script`, `auto_detect` and SOCKS4 are refused with an error. Kept across launches.
      Runtime-verified: a dead proxy blocks a new site, clearing it restores direct loads. `onProxyError` and
      proxy sign-in (`webRequest.onAuthRequired`) are inert.
- [x] **[P2]** `chrome.fontSettings` → font prefs: `getFont`, `setFont`, `clearFont`, `getFontList`, `onFontChanged`.
      Done (2026-11-17): the standard family and default / fixed sizes (WebKit private prefs) and minimum
      size (Settings) can be set; WebKit has no accessor for the other generic families, so they report
      their macOS defaults as `not_controllable`. `getFontList` lists system fonts only (pages don't get
      user-installed ones). Runtime-verified: the page font changes live and in new tabs.

## D. [P3] Hard / niche inert namespaces (list for completeness; likely leave as no-ops)

Reviewed 2026-11-17: still no-op stand-ins. Neither WebKit nor macOS gives Tuff anything to build these on.

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
- [x] **[P3]** `declarativeNetRequest.testMatchOutcome` — absent from WebKit, not stubbed. Add a shim
      stand-in (or implement against the DNR engine) so rule-tester extensions don't crash.
      Done (2026-11-17): resolves `{ matchedRules: [] }` (WebKit can't say which rules match).
- [x] **[P3]** `extension.getExtensionTabs` — absent, not stubbed (legacy). Add inert stand-in.
      Done (2026-11-17): returns `[]` synchronously.
- [x] **[P3]** `declarativeNetRequest` constants (`MAX_NUMBER_OF_DYNAMIC_RULES`, `MAX_NUMBER_OF_REGEX_RULES`,
      `MAX_NUMBER_OF_SESSION_RULES`, …) — define sensible values in the shim.
      Done (2026-11-17): Chrome's published values, plus `DYNAMIC_RULESET_ID` / `SESSION_RULESET_ID`. Runtime-verified.

### Inert events (WebKit lacks them; shim stand-ins never fire)
- [x] **[P2]** `webNavigation.onHistoryStateUpdated` + `onReferenceFragmentUpdated` — SPA / hash navigation.
      Drive from `WKNavigationDelegate` (same-document navigations) in Tab+Web.swift.
      Done (2026-11-17): from `didSameDocumentNavigation` via event push; WebKit's duplicate report for a hash change is
      dropped; `{ url: [UrlFilter] }` listener filters honoured. Runtime-verified (pushState, hash, back ×2).
- [x] **[P2]** `webNavigation.onCreatedNavigationTarget` — window.open / target=_blank. Drive from
      `createWebViewWith` (Tab+Web.swift) / `openNewTabUsing`.
      Done (2026-11-17): from `createWebViewWith`, with `sourceTabId` and `tabId`. Runtime-verified.
- [ ] **[P3]** `webNavigation.onTabReplaced` — rare; inert acceptable.
- [x] **[P3]** `tabs.onZoomChange` — fire from `Tab.setZoom` (Tab.swift:380).
      Done (2026-11-17): from `applyZoom` (also when a site's saved zoom is applied). Runtime-verified.
- [x] **[P3]** `windows.onBoundsChanged` — fire from `windowDidResize` (BrowserWindowController.swift).
      Done (2026-11-17): resize / move, debounced 0.3 s; listeners get `windows.getLastFocused()`.
- [ ] **[P3]** `runtime.onSuspendCanceled` / `onUpdateAvailable` / `onRestartRequired` /
      `onBrowserUpdateAvailable` / `onUserScriptMessage` / `onUserScriptConnect` / `onConnectNative` — mostly
      lifecycle/debug; wire the ones that become relevant.
      Looked at 2026-11-17: `onUpdateAvailable` isn't needed, since extension updates install at once
      (`ExtensionUpdates.swift`); Chrome only fires it when it has to wait. The rest stay inert.
- [ ] **[P3]** `webRequest.onActionIgnored`, `action.onUserSettingsChanged`, `commands.onChanged`,
      `declarativeNetRequest.onRuleMatchedDebug`, `extension.onRequest`/`onRequestExternal` — minor/debug.

---

## F. [BUG] Extension-code correctness

- [x] **[BUG]** **Mute lost on sleep/wake** — `Tab.wake()` (Tab.swift:102) re-applies `pageZoom` but not
      `isMuted`. Re-apply mute on wake and after navigation (`_setPageMuted:` is per-page). Also
      `setMuted` (Tab.swift:386) sets `isMuted` then returns early when `webView == nil` without firing
      `tabDidChange` — keep state consistent.
- [x] **[BUG]** **No extension auto-update** — `updateFromStore` (ExtensionManager.swift:603) always
      re-downloads with no version check. Add version comparison + a periodic update check; fire
      `runtime.onUpdateAvailable` when relevant.
      Done (2026-11-17): `Extensions/ExtensionUpdates.swift` asks the Chrome update service (`updatecheck`) / AMO API for the
      latest version, compares numerically, and reinstalls only when newer; checks a minute after launch, then every 5 h.
      The row's menu item is now "Check for Update" (toast when up to date). `onUpdateAvailable` not fired (updates install directly).
- [x] **[BUG]** `chromeDownloadURL` (ExtensionManager.swift:424) hardcodes `prodversion=140.0.0.0` and
      `arch=arm64`. Use a current prodversion and the host's real arch; honour `minimum_chrome_version`.
      Done (2026-11-17): prodversion follows Chrome's four-weekly releases (`chromeProdVersion`), arch is `arm64` / `x86-64`;
      the store download uses the current Chrome UA too.
- [x] **[BUG]** `.zip` Firefox add-ons misdetected — `performInstall` (ExtensionManager.swift:534) keys
      off `.xpi` only. Sniff the manifest (`browser_specific_settings.gecko`) to pick the source/origin.
      Done (2026-11-17): `isGeckoManifest` (also old `applications.gecko`) switches a .zip to the Firefox source.
- [x] **[BUG]** Shim skips HTML pages with no `<script>` tag — `ExtensionCompat.patch`
      (ExtensionCompat.swift:176). Inject before `</head>`/`<body>` as a fallback so every page gets it.
      Done (2026-11-17): `shimInsertionPoint` falls back to `</head>`, `<body`, after the doctype, or the top. Shim level bumped to 3
      so installed extensions are re-patched.
- [x] **[BUG]** `SidePanelManager.open` (SidePanels.swift:154) guard `url(...) != nil || tabOptions[id]?.isEmpty == false`
      can open a panel with no resolvable URL on the current tab. Tighten the condition.
      Done (2026-11-17): only opens if this tab resolves a panel URL, or another open tab has options that resolve one.
- [ ] **[BUG]** `finishInstall` (ExtensionManager.swift:595) hardcoded 800 ms teardown sleep — replace with
      a deterministic wait (completion/callback) to avoid the race on slow machines.
      Looked at 2026-11-17: WebKit has no public signal for the old background worker going away
      (`unload` returns at once; `isLoaded` flips immediately), so there is nothing to wait on yet.
- [x] **[BUG]** Native messaging (NativeMessaging.swift): `send()` silently drops when the process isn't
      running / JSON invalid — surface an error to the extension. Capture stderr for diagnostics.
      Add system-wide Chromium dir to `searchDirectories`.
      Done (2026-11-17): `send` throws (not running / not JSON / too big / write failed); `sendNativeMessage` rejects and ports
      disconnect with the error. Exit status + last stderr line reach the extension; stderr tail is logged. Added
      `/Library/Application Support/Chromium/NativeMessagingHosts`.
- [x] **[BUG]** `handleKeyEvent` (ExtensionManager.swift:847): handle `_execute_page_action`; define
      deterministic precedence when multiple extensions register the same shortcut.
      Done (2026-11-17): `_execute_page_action` runs the action (or toggles the panel); first-installed extension wins.
- [x] **[BUG]** `BrowserState.close` for pinned/favorites (BrowserState.swift:219) resets to `homeURL`
      without notifying extensions — fire a URL change so `tabs.onUpdated` isn't stale.
- [x] **[BUG]** `SocketRelay` (ExtensionManager.swift:907) mutates the extension's *shared* configuration
      preferences (`inactiveSchedulingPolicy`) — copy the configuration so other web views aren't affected.
      Done (2026-11-17): `ExtensionManager.hiddenPageConfiguration` gives socket relay, event relay and offscreen pages
      their own `WKPreferences` (a copied configuration still shares them).
- [x] **[BUG]** Fragile shim markers — module-worker re-patch (`refresh`, ExtensionCompat.swift:214)
      depends on the first 40 bytes + a unique `})();` line. Make the boundary robust (explicit sentinel).
      Done (2026-11-17): module workers carry `// __tuff_compat_start__` / `// __tuff_compat_end__`; old workers still found the old way.

---

## G. [BUG] General app correctness

- [x] **[BUG]** Latent crash — `BrowserState.currentSpace` (BrowserState.swift:81) and `profile(for:)` (:86)
      index `[0]` without an empty guard. Add safe fallbacks.
      Done (2026-11-17): placeholder space/profile before restore; `restore` always leaves at least one profile and space.
- [x] **[BUG]** `closeIdleTabs` (BrowserState.swift:837) doesn't check `tab.isLoading` (unlike
      `sleepIdleTabs`) — a stuck loading tab can be auto-closed. Add the check.
- [x] **[BUG]** `DownloadManager.uniqueDestination` (Stores.swift:273) check-then-use race for concurrent
      same-name downloads; empty filename yields `" 2"`, `" 3"`. Reserve atomically; handle empty names.
- [x] **[BUG]** `FaviconStore.fetchIcon` (Stores.swift:148) uses a separate ephemeral `URLSession`, not the
      tab's profile store — auth-gated favicons fail and per-profile isolation is bypassed. Fetch in-context.
      Done (2026-11-17): still its own cookie-less session, but each request now carries the cookies the page's
      profile store holds for the icon's address (`WKHTTPCookieStore`, RFC 6265 domain / path / secure
      matching), the page's user agent and an origin referrer. Unit-tested; favicons runtime-checked.
- [x] **[BUG]** `WebEngine` sets `developerExtrasEnabled` via KVC without a `responds` guard
      (WebEngine.swift:90, :131) — guard it like the other private prefs to avoid `NSUndefinedKeyException`.
- [x] **[BUG]** `BrowserState.newTab` before restore (BrowserState.swift:172) returns an orphaned `Tab`
      (`browser == nil`, in no space). Queue properly or document the contract.
      Done (2026-11-17): the real tab is returned (owned by the window) and inserted into the current space when `restore` finishes.
- [x] **[BUG]** `Tab.handleLoadFailure` (Tab+Web.swift:135) loads a simulated error page even in extension
      web views where it may not render. Skip/branch for extension pages.
      Done (2026-11-17): extension pages log the failure and keep what's showing.

---

## H. [POLICY] AGENTS.md violations (native dialogs)

- [x] **[POLICY]** `UpdateController.checkForUpdates` (AppDelegate.swift:284) shows a native `NSAlert`
      ("Updates aren't set up for this build") — user-visible via the menu. Replace with a `Prompt` card.
- [x] **[POLICY]** `PromptPresenter.fallbackAlert` (Prompt.swift:126) uses `NSAlert` when no host window
      exists. Rare, but still user-visible — replace or justify per the "developer-only" exception.
      Done (2026-11-17): `NSAlert` removed. The main window is brought back to hold the card; a gone Incognito window answers "no".

---

## I. [VERIFY] Confirm before acting

- [x] **[VERIFY]** **`sidePanel` bypass risk** — the shim installs Tuff's bridge only `if absent(root,'sidePanel')`.
      The WebKit binary contains `sidePanel`/`getLayout`/`setLayout` strings (possibly generic false positives).
      At runtime, check whether WebKit exposes any `sidePanel` object; if it does, Tuff's working bridge is
      bypassed for WebKit's partial one. If so, force Tuff's implementation.
      Checked 2026-11-17 in an extension page: `chrome.sidePanel.open` is the shim's own function, so WebKit
      exposes no `sidePanel` and Tuff's bridge is the one in use. Nothing to change.
- [x] **[VERIFY]** **`devtools_page` / `chrome.devtools.*`** — no host handling exists; binary has
      `inspectedWindow`/`devtools_page` but lacks `getResources`/`setContent`. Confirm whether React/Redux/Vue
      DevTools can work at all; if not, document as unsupported (see J).
      Checked 2026-11-17 (new `inspect` debug command opens Web Inspector): WebKit loads an extension's
      `devtools_page` when Web Inspector opens, with no Tuff code needed. It provides
      `devtools.inspectedWindow.eval` / `reload` / `tabId`, `devtools.panels.create` / `themeName` /
      `onThemeChanged`, and `devtools.network`. Missing: `inspectedWindow.getResources`, `panels.elements` /
      `sources` sidebars and `openResource`. So DevTools that only add a panel and `eval` in the page can work;
      ones needing the Elements sidebar won't fully work. Not tried with React / Vue DevTools themselves.
- [x] **[VERIFY]** Re-confirm any "inert" namespace before implementing it — generic binary strings
      (`notifications`, `downloads`, `cpu`, `search`, …) false-positive; trust distinctive camelCase API
      identifiers and a runtime `typeof chrome.X` check in an extension page.
      2026-11-17: done for this batch. Every namespace added here was checked to be absent at runtime first
      (the shim only fills in names WebKit leaves undefined).

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
- [x] **[P1]** **"{site} is in full screen" banner.** When a page goes full screen (a YouTube or
      Netflix video), show a small card at the top: the site's name and "Press Esc to exit full
      screen", fading after a few seconds, as Chrome and Safari do. Drive it from KVO on
      `WKWebView.fullscreenState`; reuse the toast/card look (no `.shadow`, see AGENTS.md).
      Done (2026-11-17): `Window/FullScreenBanner.swift` — a click-through panel over WebKit's full-screen window (the
      browser window isn't visible then), 3.5 s. Runtime-verified via `fsbanner` (shown, then faded).
- [ ] **[P1]** **Screen sharing (`getDisplayMedia`).** Nothing handles it, so "Present" in Meet,
      Zoom and Teams fails. Needs WebKit's display-capture permission delegate (private
      `_webView:requestDisplayCapturePermissionForOrigin:…` and the screen-capture preference)
      plus a `SitePermissionKind.screen` and a card.
- [x] **[P1]** **Camera / microphone in-use indicator** on the tab row (and horizontal tab), with a
      click to stop: observe `cameraCaptureState` / `microphoneCaptureState`, stop with
      `setCameraCaptureState(.none)` / `setMicrophoneCaptureState(.none)`.
      Done (2026-11-17): `CaptureIndicator` (sidebar rows, split halves, horizontal tabs); its menu pauses / resumes / stops;
      also in the tab's context menu. Not exercised with a real camera here.

### Sign-in and passwords
- [ ] **[P1]** **Passkeys / WebAuthn.** Third-party WKWebView browsers need Apple's
      `com.apple.developer.web-browser.public-key-credential` entitlement (Developer ID + a request
      to Apple). Without it passkeys and security keys fail on most sites. Test on webauthn.io.
- [ ] **[P1]** **Password saving and autofill.** Nothing built in (HTTP sign-in is `.forSession`
      only); today it's extensions (1Password, Bitwarden). Either a Keychain-backed store with a
      save card and fill-on-focus, or document the extension route in onboarding.

### Privacy and site controls
- [x] **[P1]** **"Pop-up blocked" indicator.** With Block pop-ups on, blocked `window.open`s vanish
      silently. Show an icon in the address pill with "Allow pop-ups from {site}" (per-site
      setting already exists in `SiteSettings`).
      Done (2026-11-17): `Web/PopupBlocker.swift` notices `window.open` returning null; the pill shows a button listing
      them (open one, "Always Allow Pop-ups from {site}", Dismiss). Cleared on navigation. Runtime-verified.
- [x] **[P2]** **Per-site website data.** Remove one site's cookies and storage (Settings → Websites
      and the page menu), and clear by time range (last hour / today / all). Today it's "Remove
      All" only.
      Done (2026-11-17): Settings → Privacy → Website data has "Remove recent data" (hour / today / 7 days / 4 weeks) and a
      searchable "Data by site" list; page menu → Site Settings has "Clear Website Data…". All behind Prompt cards.
- [x] **[P2]** **List "open in app" answers** ("Always allow {site} to open {App} links",
      `ExternalAppLinks`) in Settings → Websites, each removable. Today only "Forget All" clears them.
      Done (2026-11-17): "Links that open apps" group, with the app's name.
- [ ] **[P2]** **HTTPS-first mode:** try https for every site, with a warning page before falling
      back to http. `upgradeKnownHostsToHTTPS` only covers sites WebKit knows support it.
- [ ] **[P3]** Web Push (notifications only arrive while Tuff is running).

### History, search and tabs
- [x] **[P2]** **History keeps one entry per page** (last visit only), so a page seen yesterday and
      today shows under today only. Keep a per-visit log.
      Done (2026-11-18): visit dates persist alongside each page; History shows one row per visit, date-range
      deletion preserves other visits, and `history.getVisits` returns them. Unit-tested and runtime-verified.
- [x] **[P2]** **History per profile.** School's command bar suggests Home's history today.
      Done (2026-11-18): entries, imports, suggestions, top sites and extension APIs are profile-scoped;
      existing history moves to the original profile. Runtime-verified with an empty School space.
- [x] **[P2]** History menu: **Recently Closed** and **recent pages** submenus.
      Done (2026-11-17): `App/HistoryMenu.swift` fills them as the menu opens (⌘-choose opens in a new tab). Runtime-verified.
- [x] **[P2]** Command bar **zero state** (⌘T on an empty field: top sites, recent tabs) and
      **Paste and Go** in the address pill's menu.
      Done: Paste and Go (2026-11-17) in the address bar's right-click menu and Edit menu; zero state
      (2026-11-18) shows recent tabs and this profile's top sites, with Return activating the selection.
- [ ] **[P2]** **Translate page** (Apple's Translation framework).
- [ ] **[P3]** Per-site user agent; text-only zoom. ⌥-click a link to download it done (2026-11-18).
- [ ] **[P3]** A quick "save for later" / bookmarks manager (favourites and pinned tabs cover most of it).

### Quality
- [x] **[P2]** **Accessibility.** One `accessibilityLabel` in the whole UI; the 42 `IconButton`s
      only have tooltips, so VoiceOver reads symbol names. Label icon buttons, tab rows, tiles.
      Done (2026-11-17): `IconButton` / `PillButton` read their tooltip (minus the shortcut); tab rows, split halves,
      horizontal tabs and favourite tiles read title + state (playing, muted, camera, loading, unloaded) and are selectable.
- [x] **[P2]** **Unit tests.** No test target. Start with `BrowserState.resolve`, `Tab.samePage`,
      `Tab.zoomStep`, `AdvancedSettings.currentMajorVersion`, `SitePermissions.decision`.
      Done (2026-11-17): `TuffBrowserTests` target, `make test`. Expanded on 2026-11-18 to 54 tests covering
      the CDL handoff's permission, metadata, download, torrent, extension, cookie and browser regressions. The host app
      opens no window and loads no profile under XCTest. 2026-11-18: added `SitePermissions.decision`, per-visit /
      per-profile history and extension-download destination coverage.
- [ ] **[P3]** Localization (no strings are localizable yet).

---

### Suggested order of attack
1. **Section A** (P0 host-adapter methods) — small, self-contained, immediately fixes real APIs.
2. **Section F mute bug + Section H policy** — quick correctness/rule wins.
3. **Section B** (P1 namespaces) — biggest functionality payoff; history/downloads/notifications/identity/offscreen first.
4. **Section E** webNavigation SPA events, then **C**, then the rest.
5. Keep **I (verify)** ahead of any sidePanel/devtools work.