# Tuff handoff plan

## Objective

Fix the confirmed security, crash, persistence, and extension API issues from the audit without regressing browser performance or extension compatibility. Add regression coverage before moving to new features.

**Baseline:** working tree clean; `make test` passes all 31 tests. Runtime probes confirmed the extension permission bypass and broken `tabs.create` behavior; a standalone probe confirmed the torrent metadata crash.

## Project constraints

- Use custom `Prompt` cards for user-facing dialogs, never native alerts.
- Do not add `.shadow` around web views or blurred containers.
- Do not enable WebKit process prewarming or grant websites user-installed fonts.
- Keep Incognito data out of persistent storage and hidden from extensions.
- Add tests to the existing `TuffBrowserTests` target.
- Update `BUGS.md` / `TODOS.md` when fixing tracked items.
- Do not promise full `webRequestBlocking`; that remains a WebKit limitation.

## Phase 1 — Security and destructive failures

### 1. Authorize every native extension API

Files:

- `TuffBrowser/Extensions/ExtensionCompat.swift`
- `TuffBrowser/Extensions/ExtensionAPIs.swift`
- `TuffBrowser/Extensions/ExtensionManager.swift`

Work:

- Define a central namespace/method → required permission mapping.
- Enforce it in `ExtensionAPIBridge`, not only by hiding JavaScript namespaces.
- Use the extension context’s current granted permissions so optional grants and revocations work.
- Cover destructive and sensitive routes first: `history`, `downloads`, `browsingData`, `management`, `privacy`, `proxy`, `contentSettings`, `userScripts`, and notifications.
- Leave the underlying `tabs.create` transport and internal event subscription calls available without unrelated permissions.

Done when:

- An extension without `history`, `downloads`, or `management` cannot call those APIs.
- Declaring and granting the permission enables them.
- Optional permission revocation takes effect without reloading the app.
- Internal bridge/event calls still work.

### 2. Make torrent metadata parsing non-trapping

File: `TuffBrowser/Downloads/Engine/TorrentMeta.swift`

Work:

- Replace unchecked file-length and total-size arithmetic with checked operations.
- Validate conversions to `Int`, piece counts, and allocation sizes before allocating.
- Add defensible limits for v2 total size, piece count, tree depth, and file count.
- Reject malformed metadata with `TorrentError`, never a trap.

Done when:

- The ten-large-files overflow reproducer returns an error.
- Fuzzed/truncated/oversized v1, v2, and hybrid metadata cannot crash the parser.
- Existing torrent creation and verification tests still pass.

### 3. Stop Incognito torrents entering persistent state

Files:

- `TuffBrowser/Downloads/TorrentBridge.swift`
- `TuffBrowser/Downloads/DownloadsPage.swift`
- `TuffBrowser/Downloads/Engine/TorrentSession.swift`

Recommended short-term behavior:

- Decline to add torrents from Incognito with a custom explanatory card.
- Keep the global torrent list and controls out of Incognito’s downloads page.

A separate nonpersistent torrent session can be a later feature.

### 4. Preserve extension state during updates

Files:

- `TuffBrowser/Extensions/ExtensionManager.swift`
- `TuffBrowser/Extensions/ExtensionUpdates.swift`

Preserve at least:

- `enabled`
- `linkedTo`
- `pinned`
- `sidePanel`

A disabled extension may be updated on disk, but must not load or become enabled automatically.

## Phase 2 — Extension API correctness

### 5. Complete tab creation and movement notifications

Files:

- `TuffBrowser/Extensions/ExtensionManager.swift`
- `TuffBrowser/Extensions/ExtensionBridge.swift`
- `TuffBrowser/Model/BrowserState.swift`

Work:

- Honor `parentTab`, `index`, `shouldBePinned`, and reader-mode options in `openNewTabUsing`.
- Translate WebKit’s window-wide index correctly into Tuff’s space/tab collections.
- Capture the old index before a move and call `didMoveTab` afterward.
- Report `.pinned` when moving between pinned and regular sections.
- Make `tabs.duplicate` use the existing history-preserving duplicate machinery.

Test with non-default new-tab positioning, multiple spaces, drag reordering, pin/unpin, and opener lookup.

### 6. Reconnect `chrome.downloads` to the real download engine

Files:

- `TuffBrowser/Extensions/ExtensionDownloads.swift`
- `TuffBrowser/Downloads/TurboDownloads.swift`
- `TuffBrowser/Model/Stores.swift`
- `TuffBrowser/Model/DownloadPersistence.swift`

Work:

- Route pause and resume separately to `DownloadManager`.
- Report paused state accurately instead of `interrupted` plus `paused: false`.
- Centralize `downloads.onChanged` emission so WebKit and turbo downloads produce equivalent state, filename, and pause events.
- Ensure failed initiation cannot leave a returned ID with no item or terminal event.
- Persist `downloads.erase` immediately so crash recovery cannot resurrect erased entries.

Test WebKit and turbo paths independently, including pause/resume, cancellation, server failure, quit/resume, and erase.

### 7. Isolate extension notifications

File: `TuffBrowser/Extensions/ExtensionNotifications.swift`

Work:

- Namespace notification identifiers by extension ID.
- Filter `getAll` to the calling extension.
- Reject `clear` for notifications owned by another extension or by a website.
- Define click/close behavior after disable, removal, and relaunch.
- Add `notifications.update` or leave it explicitly unsupported rather than accidentally undefined.

### 8. Fix dynamic script matching and native event delivery

Files:

- `TuffBrowser/Extensions/ExtensionContentScripts.swift`
- `TuffBrowser/Extensions/ExtensionEventPush.swift`

Work:

- Apply `includeGlobs` and `excludeGlobs` as filters in addition to `matches`; never widen a registration to all URLs merely because a glob is present.
- Queue event messages until the relay page has loaded.
- Flush queued messages after crash recovery and avoid duplicate delivery.
- Ensure adding a listener cannot lose an immediately following native event.

### 9. Clean up extension-owned resources

Files:

- `TuffBrowser/Extensions/ExtensionSystem.swift`
- `TuffBrowser/Extensions/ExtensionManager.swift`

Release power assertions on disable, removal, reload, and unlink-from-space. Add a regression check that display/system sleep is no longer blocked afterward.

### 10. Make settings APIs honest and precise

Files:

- `TuffBrowser/Extensions/ExtensionAPIs.swift`
- `TuffBrowser/Extensions/ExtensionBrowserAPIs.swift`
- `TuffBrowser/Extensions/ExtensionSettings.swift`

Work:

- Make history removal honor `since`.
- Preserve wildcard subdomain, scheme, and port semantics in content settings.
- Either implement true direct proxy behavior or reject `direct` with a clear unsupported error; do not silently use system proxies.

## Phase 3 — Download/torrent data correctness

### 11. Share one correct cookie matcher

Files:

- `TuffBrowser/Downloads/TurboDownloads.swift`
- `TuffBrowser/Web/InternalPages.swift`
- `TuffBrowser/Model/Stores.swift`

Reuse the RFC-style logic already used for favicons. Cover:

- `/foo` must not match `/foobar`.
- Empty request paths must behave as `/`.
- Secure, expired, domain, and path-scoped cookies.
- Redirects to another host must not receive the original host’s cookies.

### 12. Allow metadata to complete an existing magnet

File: `TuffBrowser/Downloads/Engine/TorrentSession.swift`

When a matching `.torrent` or `xs` source arrives for an existing magnet:

- Verify the source hash against the existing torrent.
- Adopt its info and initialize storage.
- Preserve saved haves, priorities, partials, and user settings.
- Start rechecking existing files where appropriate.

### 13. Make torrent crash resume consistent

Files:

- `TuffBrowser/Downloads/Engine/DiskIO.swift`
- `TuffBrowser/Downloads/Engine/Torrent.swift`
- `TuffBrowser/Downloads/Engine/TorrentSession.swift`

Invariant: **never persist an arrived-block bit unless its bytes are already on disk.**

Either flush partial buffers before snapshotting them or omit unflushed blocks from resume metadata. Test with forced process termination, not only clean quit.

### 14. Fix MSE initial-payload handling

File: `TuffBrowser/Downloads/Engine/MSE.swift`

Remove the second decryption of data already decrypted in `readIA`. Add two-party tests covering:

- Outgoing and incoming encryption.
- Initial payload present and absent.
- Coalesced handshake data.
- Plaintext fallback and encryption-required mode.

### 15. Cancel all web-seed requests

File: `TuffBrowser/Downloads/Engine/WebSeed.swift`

Track every task belonging to a multi-file piece fetch, cancel all of them, and ignore stale callbacks using a fetch generation/token. Pausing or removing a torrent must stop its web-seed network activity.

## Phase 4 — General browser regressions

16. **Ad-block allowlist startup:** record skipped controllers even before lists become active; `activate` must respect them (`TuffBrowser/Web/ContentBlocker.swift`).

17. **Unsaved contenteditable text:** add dirty-state tracking for contenteditable editors before automatic sleep/close (`TuffBrowser/Model/Tab.swift`, `TuffBrowser/Model/BrowserState.swift`). Test both ordinary inputs and a contenteditable composer.

18. **History persistence:** serialize writes on a dedicated queue and guarantee newest-state-wins at quit (`TuffBrowser/Model/Stores.swift`). Test two artificially delayed writes completing in reverse order.

## Final verification

For each phase:

```bash
make test
make build
```

Then use a fresh scripted profile:

```bash
scripts/debug-run.sh "wait 2; info; quit"
```

Before closing the handoff:

- Re-run the no-permission extension probe and a properly granted counterpart.
- Re-run the malformed torrent reproducer and torrent engine tests.
- Exercise WebKit and turbo downloads through their extension APIs.
- Verify Incognito leaves no torrent, history, download-list, or permission state behind.
- Run the full suite and review `git status` for generated artifacts.

Defer screen sharing, passkeys, password autofill, and other new features until these correctness fixes are complete.
