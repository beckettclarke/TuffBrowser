# Known bugs

Last updated 2026-11-12. Everything found in the extension / keyboard / focus sweep is fixed (not
committed yet). Two things are left over.

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

New debug-script commands (debug builds only): `press [cmd+][shift+][opt+][ctrl+]<key|tab>` sends
a real key event, and `responder` logs what has keyboard focus.
