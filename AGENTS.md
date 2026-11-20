# Tuff (TuffBrowser)

## Dialogs: always custom, never native

- **Do not use `NSAlert`, `.alert(...)`, `.confirmationDialog(...)` or other native macOS dialogs
  for anything a user will see.** They clash with the app's look. The only exception is niche
  debugging output that realistically only the developer will ever see.
- Every confirmation, warning or notice uses the app's own card: build a `Prompt` and show it
  with `PromptPresenter.present(_:)` (`TuffBrowser/Window/Prompt.swift`). It returns `true` when
  the user confirms. Set `host: .settings` when it is raised from the Settings window so the
  card covers that window instead of jumping to the browser window.
- Give the card an icon (`icon`, or an SF Symbol via `symbol` / `symbolColor`), a clear
  title, and a message that says what will happen. Use `destructive: true` for anything that
  deletes or can't be undone.
- **The main action always shows its keyboard shortcut** as a `KeyHint` chip inside the button:
  ⌘↩ for destructive actions (so a stray Return can't confirm them), ↩ otherwise, and Esc
  cancels. `Prompt` handles this automatically; any new dialog-like UI must do the same.
- The card also does text boxes (`fields`, with `secure` for passwords) and a checkbox
  (`checkbox`, e.g. "Don’t ask again"); use `PromptPresenter.ask(_:)` to get what was typed and
  ticked. `confirmKey` swaps the confirm shortcut when another key fits better (Quit uses ⌘Q).
  Page dialogs (`alert` / `confirm` / `prompt`, HTTP sign-in) and the quit confirmation all go
  through it.
- If an existing feature needs something the card can't do yet, extend `Prompt` / `PromptCard`
  rather than reaching for a native dialog.

## Performance: things that were measured, don't undo them casually

- **Keep the window opaque unless the Glass style is on** (`WindowSurface`). A see-through
  window more than doubles the GPU time of every frame a page draws (25% → 59% of an M1's GPU
  on a scrolling page). Vibrancy and Solid look identical in an opaque window.
- **No `.shadow` on a view that contains a web view or a blurred backdrop.** SwiftUI derives
  it from the live pixels every frame. Use `CardShadow` / `OutlineShadow` (a path shadow).
- **Web pages don't get user-installed fonts** (`WebEngine.makeConfiguration`). Granting each
  new web process access to them cost 46 ms of blocked main thread per tab / cross-site
  navigation here, and once hung for 5 s.
- **Don't turn on WebKit's process prewarming or web-process cache.** Both hand new pages a
  suspended process, and attaching to one blocked the main thread for 0.3–0.6 s in about half
  the tries measured.
- Rows and tiles get `selected` from their list, not by asking `state.selectedTab`; views that
  change many times a second (`LoadingSpinner`, `LinkPreview`) read their own state so their parents don't re-run.
- Measuring: `hitch start` / `hitch stop <label>`, `layers <path>`, `timeopen <url>`,
  `timeload <url>`, `snapscreen <path>` in `TUFF_DEBUG_SCRIPT` (see `Support/PerfProbe.swift`).
  Page benchmarks need the screen unlocked: a locked Mac reports every page as hidden.

## Build and test

- `make build` regenerates the Xcode project from `project.yml` (XcodeGen) and builds Debug. `make build`,
  `make test` and `make release` run xcodebuild through `scripts/xcbuild.py`: a progress bar (Swift files
  compiled, ETA from the last full run, kept in `build/.xcbuild-history.json`), warnings and errors at the
  end, the total time, and the full output in `build/<label>.log`. It exits with xcodebuild's status, so a
  failed build stops `make run`.
- `make run` builds and launches.
- `make test` runs the unit tests (`TuffBrowserTests`). Under XCTest the host app opens no window and
  loads no profile (`App/main.swift`), so tests must not rely on `AppDelegate.shared`.
- Debug builds can be scripted with `TUFF_DEBUG_SCRIPT` (see `TuffBrowser/Support/DebugHooks.swift`),
  e.g. `snap` / `snapall` for screenshots and `prompt yes|no` to answer an on-screen card.

## Updates

- Flint (`Vendor/Flint`, copied from `~/Developer/ai-slop/flint`) installs GitHub Releases of
  `beckettclarke/TuffBrowser` (`Updater.app` in `App/AppDelegate.swift`). Channels: stable and nightly.
  It checks only in Release builds; Debug has its own bundle ID. Settings → About has the controls.
- Ship with `PUBLISH=1 scripts/release.sh`. The tag is `v` + `MARKETING_VERSION` and the asset is
  `Tuff-<version>.zip`. Nightlies use `MARKETING_VERSION=0.2.0-nightly.<yyyymmdd>`, counted against the
  next version.
- Flint reads releases without authentication, so the repo must be public for updates to be found.

## Changelogs

Use concise sentences that users can understand. Focus on the visible improvement, not implementation details.

Examples:
- Redesigned app icon
- New space selector dropdown in horizontal tabs mode
- Added onboarding screen
- Revamped adblocker

## Bookmarks

- `Model/Bookmarks.swift`: `BookmarkStore` keeps each profile's bookmarks (folders nest) in
  `bookmarks.json`; Incognito windows use the main window's. The `BrowserState` extension there has
  the actions (⇧⌘D bookmark / edit, open, edit, delete), all through `Prompt`.
- The bar (`Window/BookmarksBar.swift`) and the address bar's star exist only in the horizontal
  layout (`settings.tabs.showBookmarksBar`, ⇧⌘B, off by default). The vertical layout shows no
  bookmarks UI: the Bookmarks menu (`App/BookmarksMenu.swift`) and command bar results find them.

## Passwords and translation

- Passwords (`Passwords/`): `PasswordStore` keeps each profile's logins AES-GCM encrypted in
  `passwords.sealed`, key in `passwords.key`. Deliberately not the keychain: Tuff is signed ad hoc, so
  the keychain treats every update as a new app and asks for the login password. The same reason
  `Web/WebCryptoKey.swift` hands WebKit its WebCrypto key from a file. `PasswordAutofill` runs in its
  own content world; trust the frame's `securityOrigin`, never what the page posts.
- Translate (`Web/PageTranslation.swift`): Apple's Translation framework through `.translationTask`
  (`TranslationHost` in `WebCard`), or Google's keyless endpoint when the user picks it. Never send a
  page to Google without the user's choice (Settings or the card); Incognito always asks.

## Sync

- `Sync/`: Firefox Sync with a Mozilla account, so Tuff syncs with Firefox, Zen and other Tuffs
  (bookmarks, history, passwords, open tabs; not extensions). Settings → Sync (`SyncSettings.swift`).
- Sign-in is Mozilla's own page in a tab, as the Firefox for iOS OAuth client (Mozilla registers no
  clients for other browsers): `Tab+Web` hands the redirect to `SyncManager.handleRedirect`, and the
  sync key arrives as a JWE for a one-off key pair (`ScopedKeysRequest`). Account and sync state are
  AES-GCM sealed in `Sync/` (`SealedFolder`), not the keychain, for the same reason as passwords.
- Bookmarks are a three-way merge (`BookmarkMerge`, tested in `SyncTests`): Firefox's toolbar is the
  bar, its Menu / Other / Mobile folders are folders at the end of the bar (as the Firefox import makes
  them), and separators / queries are kept on the server untouched. Other kinds keep the server's last
  record and upload only changes. Unknown record fields are always preserved.
- Chrome sync isn't possible: Google only lets Chrome use it. The page points to Import instead.
- Testing without an account: `scripts/fake-sync-server.py 8765`, then a debug build with
  `TUFF_SYNC_SERVER=http://127.0.0.1:8765` and `sync fake; sync now; sync dump` in `TUFF_DEBUG_SCRIPT`.

## Downloads and torrents

- `tuff://downloads` (⌥⌘L) is an HTML page like History: `Downloads/DownloadsPageTemplate.swift`
  draws it from `dl.state` once a second; `Downloads/DownloadsPage.swift` (`DownloadsWebPage`) answers
  its `dl.*` messages. Confirmations there use `Prompt`, file pickers use NSOpenPanel / NSSavePanel.
- Web downloads: WebKit starts them; big GETs from servers that take ranges are handed to
  `HTTPTransfer` (several connections, dynamic range splitting, pause/resume across relaunches) in
  `DownloadManager.takeOver` (`Downloads/TurboDownloads.swift`). Partial files end in `.tuffpart`.
- Torrents: `Downloads/Engine/` is a self-contained BitTorrent client (Foundation, Network and
  CryptoKit only): v1/v2/hybrid, µTP + TCP, MSE, DHT (v4/v6), PEX, LSD, UPnP/NAT-PMP/PCP, web seeds.
  Everything runs on `engineQueue`; disk work on `DiskIO`. Seeding is off by default
  (`TorrentSettings.seedAfterDownload`). `TorrentBridge` ties it to the app (launch, magnets,
  .torrent files, the add sheet).
- The engine builds on its own for quick experiments, without the app:
  `swiftc -O -swift-version 5 -target arm64-apple-macos15.4 TuffBrowser/Downloads/Engine/*.swift main.swift`.
  `TorrentTests` covers encoding, v2 merkle checks, the creator, MSE and the IP filter.
