# Known bugs

Last updated 2026-11-19. The extension / keyboard / focus sweep, the 2026-11-16 security / bug
audit, the 2026-11-17 app correctness pass, and the 18-item `CDL-HANDOFF.md` correctness pass are
fixed. Two older limitations are left over. Missing features are in TODOS.md (section K).

## Left over

- **uBO's block page still says "Close this window" instead of "Go back."** Its own page history
  is only one entry long, because WebKit can't carry history into an extension's web view.
  Tuff's Back (button, ⌘[, `tabs.goBack`) now returns to the page you were on, but uBO's button
  can't, and clicking it closes the tab. A real fix would mean opening extension pages inside the
  same web view, which WebKit doesn't allow.
- **Some shortcuts still go to the page first, on purpose.** Pages can still use ⌘1–9, the ⌥⌘
  arrows, ⌘S, ⌘F, ⌘[ / ⌘] and ⌘P before Tuff gets them. Web editors rely on these, and Chrome
  doesn't reserve them either. If one ever needs reserving, add it to
  `BrowserWindowController.isReserved`.

## Fixed

| What was wrong | Where it's fixed |
|---|---|
| Ad blocking extensions blocked nothing: WebKit ignores `webRequest` block answers (full uBO: 10 of 130 on adblock.turtlecute.org while its counter said thousands). Tuff now blocks natively from the standard filter lists (91 of 130, more than uBO's own engine). | `Web/ContentBlocker.swift`, `Web/FilterListParser.swift` |
| uBO let YouTube ads through: its scriptlets come through `browser.contentScripts.register`, which was an inert stub. Now implemented natively for any extension (plus `userScripts`). | `Extensions/ExtensionContentScripts.swift` |
| The built-in blocker skipped YouTube's scriptlets and procedural cosmetic rules; mixed-domain exceptions could over-block; and an unsupported entity such as `kat.*` could be dropped while its exclusions stayed, widening one KAT rule into a global first-party script block. Failed or outdated compilations also stayed active too long. Tuff now runs cached uBO Lite advanced rulesets itself (no extension needed), preserves domain exclusions, rejects those widened rules, and rebuilds incompatible or partial caches before using them. | `Web/AdvancedContentBlocker.swift`, `Web/ContentBlocker.swift`, `Web/FilterListParser.swift` |
| A blocked ad iframe sent the whole tab to uBO's block page. WebKit reports iframe loads as `main_frame`. | `Extensions/ExtensionCompat.swift` (shim) |
| Iframes directly inside the page reported WebKit's raw id as their `parentFrameId` instead of 0. | shim |
| `webRequest` details had no `initiator` and empty `documentUrl` / `originUrl`. | shim |
| An extension with only `webRequest` got no events at all. WebKit wants `webRequestBlocking` too, which is now granted alongside it. | `ExtensionManager` (permission grant) |
| Moving into or out of an extension page lost Back history. Back now returns to the page you came from, and skips a page uBO blocked. | `Model/Tab.swift` (`moveToNewWebView`, `goBack`) |
| Browser shortcuts (⌘T, ⌘L, ⌘W, ⇧⌘T, ⌘Q, ⌃⌘N, ⌥⌘N, ⌃Tab, ⌃⇧Tab) went to the page first. Pages could swallow them, and typing went into the page meanwhile. | `BrowserWindowController.handleKeyDown` |
| The key and scroll monitors never swallowed anything (`self?.handle($0) ?? $0` turned nil back into the event). ⌘W closed two tabs, Esc in the find bar reached the page, and swipe scrolling reached the page. | `BrowserWindowController.installMonitors` |
| Switching the open command bar between ⌘T and ⌘L kept the old text. | `CommandBar/CommandBar.swift` (`.id(mode)`) |
| `focusWebView` pulled focus out of the find bar and out of dialog cards. | `Model/BrowserState.swift` |
| ⌘F with the find bar already open didn't always refocus it. | `AppDelegate.findInPage`, `BrowserState.focusFindField` |
| The command bar field sometimes didn't take focus when it appeared. | `KeyTextField` retries |
| Turning off "Restore session" wiped spaces, pinned tabs, favourites and profiles. Now only open tabs are dropped. | `BrowserState.restore` |
| Pages could open tabs without a click (no pop-up blocker). Settings → Privacy → Block pop-ups. | `WebEngine` (`javaScriptCanOpenWindowsAutomatically`) |
| Background tabs' `alert` / `confirm` / `prompt` and HTTP sign-in were silently dropped. They now wait until the tab is shown; a page can be stopped from showing more. | `Tab+Web` (`askForPage`), `Tab.didBecomeVisible` |
| Mute was lost when a tab slept and woke. | `Tab.wake`, `Tab.setMuted` |
| A background tab whose page crashed stayed blank; a page that kept crashing reloaded forever. | `Tab+Web` (`webViewWebContentProcessDidTerminate`) |
| Site permissions from Incognito were saved to disk, normal-window grants applied in Incognito, and answers were per host (http and https shared them). | `SitePermissions` (per origin, Incognito in memory) |
| Single-page-app navigation (pushState) never reached history. | `Tab+Web` (`didSameDocumentNavigation`), `HistoryStore.updateTitle` |
| Context menu "Download Image" / "Download Linked File" did nothing (no delegate for the download). Added "Save Image As…" / "Save Linked File As…". | `Tab+Web` (`contextMenuDidCreateDownload`), `TuffWebView.willOpenMenu` |
| Replacing a file from the save panel deleted it before the download finished. | `DownloadManager` (`partialFile`) |
| Favicons were downloaded again on every page load. | `FaviconStore.freshIcon` |
| Menu items were never disabled. | `AppDelegate.validateMenuItem` |
| Find bar, command bar, prompt and permission cards used `.shadow` over a blurred backdrop. | `CardShadow(hollow:)` |
| "index.html" / "node.js" opened as websites; IPv6 addresses were searched. | `BrowserState.resolve` |
| "Closing" an unloaded pinned tab kept its old history (it woke on the page it had left), and extensions weren't told. | `Tab.sleep(resetToHome:)` |
| Any page could launch other apps (`zoommtg:`, `vscode:`, `x-apple.systempreferences:`…) without asking, even from a redirect. A card now asks ("Always allow" per site and app); typed addresses and clicked mail / phone links still open straight away. | `Web/ExternalAppLinks.swift` |
| Websites could reach `tuff://` pages: send a tab or pop-up to `tuff://source` (a fetch with all the tab's cookies, past SameSite), or load `tuff://favicon` as an image to probe History. Only Tuff opens them now, and only Tuff's pages load from them. | `Tab+Web` (`mayOpenInternalPage`), `InternalPageHandler` |
| Incognito leaked to extensions: `history.onTitleChanged` for Incognito pages, Incognito downloads in `downloads.*` and its events, `sessions.onChanged`. | `Tab.observe`, `DownloadManager.track`, `BrowserState` |
| Incognito downloads showed in the normal window's downloads list (and stayed after the Incognito window closed). Each kind of window lists its own; Incognito's leave with the last Incognito window. | `DownloadManager` (`items(isPrivate:)`, `forgetPrivateItems`) |
| Search suggestions used `URLSession.shared`, whose cookie jar sat outside every profile (never cleared, shared with Incognito). | `CommandBarView.suggestionSession` |
| An unreadable `session.json` started a fresh session and the next save overwrote it, losing every space, pinned tab, folder and favourite. It is kept aside and the copy from the last good launch is used. | `BrowserState.readSession` |
| Session saves encoded every tab's history on the main thread. Encoding and writing now happen on a background queue. | `BrowserState.saveNow` |
| Error pages (offline, can't find host, bad certificate) were recorded in History: typos became command-bar completions and real pages got titles like "You're offline". | `Tab.showErrorPage`, `showingErrorPage` |
| Favicons were cached per host, so Google Docs, Sheets and Slides (all docs.google.com) showed one icon. Icons are cached by their own address now. | `FaviconStore` |
| Quitting during a download dropped it with no warning and no way to resume. The quit card warns, and downloads pause with resume data for next time. | `AppDelegate.pauseDownloadsThenQuit`, `DownloadManager.pauseAllForQuit` |
| A tab opened on a download link kept the file's address, so waking it or relaunching downloaded the file again. It goes back to its page, or closes if it was opened just for the download. | `Tab.mainFrameBecameDownload` |
| Tab sleeping and closing idle tabs ignored calls with the sound off (camera / mic in use), waiting dialogs, and text typed into a form. | `Tab.isBusy`, `Tab.checkUnsavedInput` |
| Middle-click close relied on SwiftUI hover, which doesn't update when rows slide under a still pointer, so closing several tabs in a row missed. Now hit-tested against each row's real frame; favourites tiles take middle clicks too. | `onMiddleClick` (`MiddleClickRouter`) |
| Chrome / Firefox user agents were fixed at versions a year old. They now count up with the browsers' four-weekly releases. | `AdvancedSettings.currentMajorVersion` |
| Zoom went in ×1.1 steps (odd percentages that drifted); ⌘+ didn't work where + is its own key. Standard steps now, and ⌘+ zooms in. | `Tab.zoomStep`, `MainMenu` |
| Duplicate Tab copied only the address, losing back / forward history and the tab's name. | `BrowserState.duplicate` |
| Finished downloads are given Gatekeeper's quarantine flag if WebKit didn't set one (it does today; this is a fallback). | `DownloadManager.markQuarantined` |
| A session with no profiles or spaces (or a lookup before restore) indexed `[0]` of an empty array. | `BrowserState.currentSpace`, `profile(for:)`, `restore` |
| A tab asked for before the session was restored was handed back orphaned and its address queued separately. | `BrowserState.newTab` (`pendingTabs`) |
| An extension page that failed to load got a simulated error page, which can't load at an extension address. | `Tab.handleLoadFailure` |
| Extension relay pages (sockets, events, offscreen) switched off throttling for every page of their extension: a copied configuration shares its `WKPreferences`. | `ExtensionManager.hiddenPageConfiguration` |
| The Chrome Web Store download claimed Chrome 140 on arm64 on every Mac. | `ExtensionManager.chromeDownloadURL` |
| A Firefox add-on installed from a .zip was treated as a Chrome extension. | `ExtensionManager.isGeckoManifest` |
| Extensions were never updated, and "Update from Store" reinstalled without checking the version. | `Extensions/ExtensionUpdates.swift` |
| Native messaging dropped messages silently when the host wasn't running or the message wasn't JSON; host stderr was thrown away. | `NativeMessaging.send`, `ExtensionManager` |
| `_execute_page_action` shortcuts did nothing; two extensions with the same shortcut raced. | `ExtensionManager.handleKeyEvent` |
| The side panel could "open" with nothing to show on any tab. | `SidePanelManager.open` |
| Extension pages with no `<script>` tag never got the compatibility shim; module-worker shim replacement relied on fragile markers. | `ExtensionCompat.shimInsertionPoint`, `moduleStart` / `moduleEnd` |
| A card raised with the browser window closed fell back to a native `NSAlert`. | `PromptPresenter.showNext` |
| Favicons were fetched without the page's cookies, so icons behind a sign-in failed. Requests now carry the page profile's cookies for the icon's address (and no other profile's). | `FaviconStore.request(for:context:)` |
| A proxy bypass list set by an extension was dropped: Network's Swift `ProxyConfiguration.excludedDomains` doesn't keep its domains, so proxies are built with the C API. | `ExtensionSettings.proxyConfigurations` |
| Native extension APIs relied on JavaScript namespace visibility instead of checking permissions. The bridge now checks live grants centrally, including optional revocations and event subscriptions. | `Extensions/ExtensionAPIs.swift`, `ExtensionEventPush.swift` |
| Extension updates re-enabled disabled extensions and lost links, pins and side-panel preferences. | `ExtensionManager.preservingState` |
| `tabs.create` ignored opener, index, pinning and reader mode; moves lacked notifications and duplication lost history. | `ExtensionManager`, `ExtensionBridge`, `BrowserState` |
| Extension downloads had no working pause/resume, inconsistent events, orphaned initiation IDs and delayed erase persistence. | `ExtensionDownloads`, `DownloadManager`, `TurboDownloads` |
| Extension notifications shared raw system IDs, leaked `getAll`, allowed cross-owner clears and lacked `update`. | `ExtensionNotifications.swift` |
| Dynamic script globs widened matches, and native events could be lost before the relay loaded or while it recovered. | `ExtensionContentScripts`, `ExtensionEventPush` |
| Disable/remove/reload/unlink left extension power assertions alive. | `ExtensionSystem`, `ExtensionManager` |
| `browsingData` ignored history `since`; content settings flattened pattern semantics; direct proxy mode silently used system proxies. | `ExtensionAPIs`, `ExtensionBrowserAPIs`, `SiteSettings`, `SitePermissions`, `ExtensionSettings` |
| Malformed torrent sizes could overflow or trigger excessive allocations; Incognito could enter the persistent torrent session. | `Engine/TorrentMeta`, `TorrentBridge`, `DownloadsPage` |
| A .torrent could not complete an existing magnet, and resume snapshots could include blocks still buffered in memory. | `Engine/Torrent`, `TorrentSession`, `TorrentStorage` |
| MSE initial payload handling and web-seed multi-file cancellation were incorrect. | `Engine/MSE`, `Engine/WebSeed` |
| Download/source cookie matching ignored path boundaries and expiry; redirects could retain old cookies. | `FaviconStore.cookies`, `TurboDownloads`, `InternalPages`, `HTTPTransfer` |
| Every update asked for the login keychain password ("Tuff wants to use … “Tuff WebCrypto Master Key”"). WebKit kept its WebCrypto key in the keychain, and an ad hoc signed app is a new app to the keychain after each update. Tuff now hands WebKit its own key from its data folder (the old keychain key is copied over once). | `Web/WebCryptoKey.swift` |
| Signing in with a passkey without a passkey extension looped: WebKit told pages passkeys work (`getClientCapabilities`), but without Apple's browser entitlement every passkey call fails, so sign-in pages kept redirecting into their passkey step. | `Web/Passkeys.swift` |
| Ad-block allowlists were missed before rule activation; contenteditable edits were invisible to idle protection; history writes could finish out of order. | `ContentBlocker`, `Tab`, `HistoryWriter` |

New debug-script commands (debug builds only): `press [cmd+][shift+][opt+][ctrl+]<key|tab>` sends
a real key event, and `responder` logs what has keyboard focus. `move x y` and `middleclick x y` post
pointer events through the event queue (window points, origin bottom-left). Added 2026-11-17:
`popups` (what the pop-up blocker stopped), `historymenu` (fills and logs the History menu),
`pasteandgo <text>`, `capture` (camera / mic / full-screen state) and `fsbanner`. Later the same day: `inspect` (opens
Web Inspector for the selected tab, for testing `devtools_page` extensions). Added 2026-11-18: `blocker on|off|allow`
controls the built-in blocker, and `TUFF_BLOCKER_DISABLE=main,isolated,cosmetic` isolates its advanced components. Added 2026-11-19:
`https only|upgrade|off|status|proceed` switches HTTPS-first and presses the warning page's "Continue to Site".
