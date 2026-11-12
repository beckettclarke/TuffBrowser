# Tuff

A light, glassy macOS browser built on the system WebKit — Arc/Zen-style sidebar, spaces you
swipe between, a themeable translucent window, and Chrome / Firefox extension support.

- **Small**: the release app is ~5 MB (1 MB executable + Sparkle). No bundled engine.
- **Light on memory**: tabs load lazily, restored tabs stay unloaded until clicked, and
  background tabs are put to sleep after a configurable idle time.
- **Requires** macOS 15.4+ (for WebKit's `WKWebExtension` API). Built with Xcode 27 / Swift 6.

## Build & run

```bash
brew install xcodegen
make run        # generate the Xcode project, build Debug, launch
make release    # optimised build + size report
make install    # release build, copied to /Applications
```

Builds are signed ad hoc unless your keychain has a Developer ID certificate, which is picked up
automatically (`scripts/signing-args.sh`). `SIGN_KIND="Apple Development" make run` signs with a
development certificate instead, which keeps macOS from re-asking for camera / microphone
access after each rebuild.

Debug builds are a separate app (`ca.beckettclarke.TuffBrowser.debug`) with their own profile
(`~/Library/Application Support/TuffBrowser Debug`) and their own WebKit storage, so they can run
next to a Release build without sharing tabs, cookies or extension state. Only one copy of each
runs at a time: opening a second one (say, `/Applications/Tuff.app` while the one in `build/` is
open) brings the running copy forward and passes it any links. Two copies on one profile would
run every extension twice over the same storage, which leaves 1Password unresponsive.

`TuffBrowser.xcodeproj` is generated from `project.yml` and is not checked in; run `make gen`
and open it in Xcode if you prefer.

## What's in it

| Area | Notes |
| --- | --- |
| Sidebar | Favourites grid (per profile), per-space pinned tabs, tab list, drag to reorder / pin / favourite, hover-reveal when collapsed (`⌘S`) |
| Spaces | Two-finger horizontal swipe over the sidebar (tracks your fingers, tint blends between spaces), `⌥⌘←/→`, `⌃1…9`; each space has a name, icon and colour |
| Profiles | Every space belongs to a profile (e.g. Home, School). Spaces on the same profile share cookies, sign-ins and site data, and the favourites grid; each profile has its own website data store, so Home and School can be signed in to different accounts. The first profile keeps the browser's original data. Moving a space or tab to another profile reloads its pages with that profile's cookies; deleting a profile deletes its data. Pick a space's profile in its editor (click the space name) or Settings → Spaces |
| Command bar | `⌘T` (new tab) / `⌘L` (current tab): search suggestions, history, switch-to-tab |
| Appearance | Settings → Appearance: glass / vibrancy / solid, transparency, blur radius, grain, sheen, tint or per-space colours, page corner radius and gap, presets |
| Extensions | Install from the Chrome Web Store or Firefox Add-ons (the store's own "Add to Chrome" / "Add to Firefox" button reads "Add to Tuff", or "Remove from Tuff" once installed), by link / ID, or load unpacked. Toolbar popups, badges, context-menu items, shortcuts, options pages, native messaging, side panels |
| Extension linking | Extensions run in every space by default. **Use In** (Settings → Extensions, or right-click an extension's button) limits one to some profiles and/or spaces: it is loaded while one of those spaces is showing and unloaded otherwise, keeping its storage |
| Side panels | Chrome `side_panel` / `chrome.sidePanel` and Firefox `sidebar_action` / `browser.sidebarAction` extensions open in a resizable panel to the right of the page: from the extension's button (or its right-click menu), or `⌥⌘S` for the last one used |
| Media / DRM | Presents as Safari and uses WebKit's FairPlay, which is what Netflix, Spotify, Disney+ etc. use for Safari. (Widevine does not exist on WebKit.) |
| Picture in picture | Sites' own PiP buttons and the video context menu work; `⌃⌘P` (or the tab's right-click menu) pops the page's video out or back in. A video playing with sound goes into PiP when you switch away from its tab and comes back when you return (Settings → Tabs → Video). Tabs in PiP are never unloaded |
| Browser basics | Downloads, find in page, zoom, print, full-screen video, camera / mic prompts, HTTP auth, Web Inspector (`⌥⌘I`), session restore, default-browser registration |
| Updates | Sparkle 2 — see below |

## Extension compatibility

Extensions run on WebKit's WebExtensions implementation, which covers most of the Chrome API
but not everything, and behaves differently in a few places. When an extension is installed
(and again whenever the shim improves) Tuff hooks a small script
(`Extensions/ExtensionCompat.swift`) in ahead of the extension's own code — in its background
worker or page, its HTML pages and its content scripts. It:

- binds every API function to its namespace. WebKit returns `undefined` from a detached call
  such as `const getURL = browser.runtime.getURL; getURL('x')`; Chrome and Firefox do not, and
  many extensions rely on that;
- fills *missing* Chrome- and Firefox-only namespaces and events (`chrome.notifications`,
  `chrome.identity`, `storage.managed`, `browser.contentScripts`,
  `webNavigation.onCreatedNavigationTarget`, …) with inert stubs, so an extension that merely
  references them at startup still loads. Features that genuinely depend on those APIs will
  not work;
- smooths over small differences (`i18n.getMessage('')`, `requestIdleCallback`, context-menu
  URL patterns WebKit rejects, `permissions.contains` / `request` / `remove` naming a permission
  WebKit doesn't know, such as `clipboardRead`, which WebKit throws on instead of answering).

Every extension has a fixed address, so its tabs and page storage survive relaunches: Chrome and unpacked extensions keep their Web Store ID and a `chrome-extension://<id>/` origin; Firefox ones get `webkit-extension://<id>/`, with the ID derived from the add-on's slug.

**Side panels.** WebKit has no side panel or sidebar API, so Tuff hosts the panel page itself
(`Extensions/SidePanels.swift`) and the shim supplies `chrome.sidePanel` (`open`, `close`,
`setOptions` / `getOptions` including per-tab panels, `setPanelBehavior` / `getPanelBehavior`)
and `browser.sidebarAction` (`open`, `close`, `toggle`, `isOpen`, `setPanel` / `getPanel`,
`setTitle` / `getTitle`). The shim reaches Tuff by calling `tabs.create` with a private
`tuff-sidepanel:` URL, which Tuff intercepts (no tab opens); that is the one call every extension
context can make without a permission. One panel shows at a time. `onOpened` / `onClosed` never
fire, `setIcon` is ignored, and a panel only ever shows the extension's own pages (links to
websites open as tabs).

**Unpacked extensions** get the shim too, without Tuff writing into your folder: they are loaded
from a copy (`~/Library/Application Support/TuffBrowser/Unpacked/<id>`) that is synced from the
folder, `.git` aside, each time the extension loads — at launch, when enabled, and on Reload.

**Request blocking.** WebKit lets extensions watch network requests but not block or rewrite
them from script (`webRequestBlocking`). Extensions built on that — uBlock Origin and most
Firefox content blockers — install and open, but filter nothing; Tuff says so in the install
prompt. Use the Manifest V3 edition instead: uBlock Origin Lite blocks properly.

**Extension pages and websites.** WebKit only lets an extension's own pages load in a web view
made for that extension. When such a page sends the tab to a website (the "Sign in" button on
1Password's setup page, say) Tuff moves the tab to an ordinary web view; back/forward history
does not survive that hop.

**Desktop-app pairing (native messaging).** Extensions can launch the helper their desktop app
registered for Chrome or Firefox, but the helper decides whether to trust the browser.
1Password's only pairs with a browser that is in `/Applications` and signed with a Developer ID
certificate (or distributed through the App Store) — ad hoc and "Apple Development" signatures
are refused with "signed in an unsupported way". With a Developer ID certificate in your
keychain, `make install` signs with it and copies Tuff to `/Applications`; then add Tuff under
1Password → Settings → Browser → Add Browser. Without one, the extension still works on its
own: click its icon and sign in to your account inside the extension.

## Auto-updates (Sparkle)

The updater stays dormant until it is configured:

1. Build once, then create a signing key (stored in your Keychain):
   `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
2. Put the printed public key and your appcast URL in `project.yml`
   (`TUFF_SPARKLE_PUBLIC_KEY`, `TUFF_APPCAST_URL`).
3. `scripts/release.sh` builds `dist/Tuff-<version>.zip` and `dist/appcast.xml`; upload both.

For distribution outside your own Mac, sign and notarize:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID NOTARY_PROFILE=my-profile scripts/release.sh
```

## Testing without a human

Debug builds include a small scripting hook (`Support/DebugHooks.swift`) that drives the app
and snapshots its own window, using a throwaway profile:

```bash
scripts/debug-run.sh "wait 2; open https://example.com; wait 3; snap /tmp/tuff.png; info; quit"
```

Set `TUFF_EXT_DEBUG=1` while installing an extension to also forward its background
script's console output and uncaught errors into the run's log — the quickest way to see why
an extension misbehaves.

## Layout

```
TuffBrowser/
  App/         entry point, menus, Sparkle
  Model/       BrowserState (spaces, tabs, session), Tab, Space, settings, history, favicons, downloads
  Window/      window chrome, blur, traffic lights, swipe tracking, root layout, web card
  Sidebar/     sidebar UI
  CommandBar/  ⌘T / ⌘L palette
  Web/         WKWebView configuration and delegates
  Extensions/  WKWebExtension host, store installers, compatibility shim, native messaging
  Settings/    settings window
```

## Known limitations

- One browser window.
- The adjustable blur uses the window server's per-window blur radius (the same call
  terminals use); if it is ever unavailable, pick the Vibrancy style.
- No private browsing, bookmarks manager, or built-in content blocker yet (uBlock Origin Lite
  works as an extension; the full uBlock Origin cannot block on WebKit).
