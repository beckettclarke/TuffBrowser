# Extension API gaps

What Chrome and Firefox extensions can call that Tuff doesn't support, or only supports in part,
one method or event per line. Tuff's extension APIs come from WebKit (`WKWebExtensionController`)
plus the compatibility shim and native bridge in `TuffBrowser/Extensions/` (`ExtensionCompat.swift`,
`ExtensionAPIs.swift`). Anything WebKit or Tuff already fully supports isn't listed.

- `[x]` done · `[~]` partly done (the note says what's missing) · `[ ]` not supported
- "Inert" means the method or event exists so extensions don't crash at startup, but it does nothing.
  Every namespace below that has no `[x]` items is inert unless it says otherwise.

## For agents working on this

When you finish a session of extension API work, update the checkboxes below, then add one line to
the end of **Progress** at the bottom of this file (never edit earlier lines):

    APIs done: <percent>%, <done>/<total> (<new> new)

- One checkbox is one method or event (or one property, where that's the API). Keep it that way:
  don't bundle several methods into one item.
- `done` is the number of `[x]` items, and `total` is every checkbox item (`[x]`, `[~]` and `[ ]`):
  `grep -cE '^- \[x\]' TODO_EXTENSIONS.md` and `grep -cE '^- \[(x|~| )\]' TODO_EXTENSIONS.md`
- `percent` is done / total, rounded to a whole number.
- `new` is how many items you turned into `[x]` this session (this includes new items you added already done).
- Gaps you find go in as `[ ]` items, so `total` can grow. What can't or shouldn't be done goes under
  **Won't do**, without a checkbox, so it isn't counted.

## bookmarks (`ExtensionBookmarks`)

- [x] `bookmarks.get`
- [x] `bookmarks.getChildren`
- [x] `bookmarks.getRecent`: sorted by `dateAdded` (falling back to position for older bookmarks without a date)
- [x] `bookmarks.getTree`
- [x] `bookmarks.getSubTree`
- [x] `bookmarks.search`
- [x] `bookmarks.create` (including Firefox `type: "separator"`)
- [x] `bookmarks.update`
- [x] `bookmarks.move`
- [x] `bookmarks.remove`
- [x] `bookmarks.removeTree`
- [x] `bookmarks.onCreated`
- [x] `bookmarks.onRemoved`
- [x] `bookmarks.onChanged`
- [x] `bookmarks.onMoved`
- [x] `bookmarks.onChildrenReordered` (when bulk updates such as Sync reorder a folder's children)
- [x] `bookmarks.onImportBegan` (around Sync bringing in several bookmarks at once)
- [x] `bookmarks.onImportEnded`
- [x] `BookmarkTreeNode.dateAdded` / `dateGroupModified`

## declarativeContent (`ExtensionDeclarativeContent`)

- [x] `declarativeContent.onPageChanged.addRules` (rules are saved across launches)
- [x] `declarativeContent.onPageChanged.removeRules`
- [x] `declarativeContent.onPageChanged.getRules`
- [x] `declarativeContent.PageStateMatcher` (`pageUrl`, `isBookmarked` and `css` selectors)
- [x] `declarativeContent.ShowAction`
- [x] `declarativeContent.ShowPageAction`
- [x] `declarativeContent.SetIcon`
- [x] `declarativeContent.RequestContentScript` (once per page, after it loads)

## system.display

- [x] `system.display.getInfo`
- [x] `system.display.getDisplayLayout`
- [x] `system.display.onDisplayChanged` (only when what `getInfo` reports changes)

## debugger

- [x] `debugger.attach` (tabs)
- [x] `debugger.detach`
- [~] `debugger.sendCommand`: the commands extensions drive pages with (`Input` mouse, keys, text and
  drags as trusted events, `Runtime.evaluate`, `Page` dialogs / navigation / load events / screenshots,
  `Network` events, focus emulation); no `DOM`, `CSS`, `Debugger`, `Target` or `Fetch` domains
- [x] `debugger.getTargets` (tabs)
- [x] `debugger.onEvent`
- [x] `debugger.onDetach`

## pageCapture

- [x] `pageCapture.saveAsMHTML` (repacked from WebKit's Web Archive; `ExtensionPageCapture`)

## readingList (`ExtensionReadingList`)

- [x] `readingList.addEntry` (saved per profile in `reading-list.json`)
- [x] `readingList.removeEntry`
- [x] `readingList.updateEntry`
- [x] `readingList.query`
- [x] `readingList.onEntryAdded`
- [x] `readingList.onEntryRemoved`
- [x] `readingList.onEntryUpdated`

## gcm / instanceID (push messaging)

- [ ] `gcm.register`
- [ ] `gcm.unregister`
- [ ] `gcm.send`
- [ ] `gcm.onMessage`
- [ ] `gcm.onMessagesDeleted`
- [ ] `gcm.onSendError`
- [ ] `instanceID.getID`
- [ ] `instanceID.getCreationTime`
- [ ] `instanceID.getToken`
- [ ] `instanceID.deleteToken`
- [ ] `instanceID.deleteID`
- [ ] `instanceID.onTokenRefresh`

## tabCapture / desktopCapture

- [ ] `tabCapture.capture`
- [ ] `tabCapture.getCapturedTabs`
- [ ] `tabCapture.getMediaStreamId`
- [ ] `tabCapture.onStatusChanged`
- [ ] `desktopCapture.chooseDesktopMedia`
- [ ] `desktopCapture.cancelChooseDesktopMedia`

## ttsEngine (`ExtensionTTS`)

- [x] `ttsEngine.updateVoices` (and static manifest `tts_engine.voices`)
- [x] `ttsEngine.sendTtsEvent`
- [x] `ttsEngine.onSpeak`
- [x] `ttsEngine.onStop`
- [x] `ttsEngine.onPause`
- [x] `ttsEngine.onResume`

## webAuthenticationProxy (`ExtensionWebAuthn`)

- [x] `webAuthenticationProxy.attach`
- [x] `webAuthenticationProxy.detach`
- [x] `webAuthenticationProxy.completeCreateRequest`
- [x] `webAuthenticationProxy.completeGetRequest`
- [x] `webAuthenticationProxy.completeIsUvpaaRequest`
- [x] `webAuthenticationProxy.onCreateRequest`
- [x] `webAuthenticationProxy.onGetRequest`
- [x] `webAuthenticationProxy.onIsUvpaaRequest`
- [x] `webAuthenticationProxy.onRemoteSessionStateChange`
- [x] `webAuthenticationProxy.onRequestCanceled`

## dns / captivePortal / pkcs11 (Firefox)

- [x] `dns.resolve` (`canonical_name`, `disable_ipv4` / `disable_ipv6`; never `isTRR`)
- [x] `captivePortal.getState` (`ExtensionCaptivePortal`, `NWPathMonitor` + Apple captive probe)
- [x] `captivePortal.getLastChecked`
- [x] `captivePortal.onStateChanged`
- [x] `captivePortal.onConnectivityAvailable`
- [x] `pkcs11.installModule` (Firefox; `ExtensionPKCS11` native manifest discovery and PKCS#11 C ABI)
- [x] `pkcs11.uninstallModule`
- [x] `pkcs11.isModuleInstalled`
- [x] `pkcs11.getModuleSlots`

## webRequest

WebKit only lets listeners watch requests and ignores what they return (`blocking`, `asyncBlocking`
and `extraHeaders` are dropped), so the first four need WebKit. Tuff's own blocker covers ads.

- [ ] `webRequest.onBeforeRequest` blocking (`cancel`, `redirectUrl`)
- [ ] `webRequest.onBeforeSendHeaders` blocking (`requestHeaders`)
- [ ] `webRequest.onHeadersReceived` blocking (`responseHeaders`, `redirectUrl`)
- [ ] `webRequest.onAuthRequired` blocking (`authCredentials`)
- [ ] `webRequest.onActionIgnored`
- [ ] `webRequest.filterResponseData` (Firefox)
- [ ] `webRequest.getSecurityInfo` (Firefox)

## declarativeNetRequest

- [x] `declarativeNetRequest.updateStaticRules` (persists disabled static rule IDs and filters staged rulesets; `ExtensionDNR`)
- [x] `declarativeNetRequest.getDisabledRuleIds`
- [x] `declarativeNetRequest.getAvailableStaticRuleCount` (counts enabled static rulesets on disk against the static budget)
- [x] `declarativeNetRequest.testMatchOutcome` (evaluates enabled static, dynamic and session rules; `ExtensionDNR`)
- [ ] `declarativeNetRequest.onRuleMatchedDebug`
- [~] `declarativeNetRequest.MAX_*` limits: Chrome's figures, not WebKit's

## tabs

- [x] `tabs.discard` (sleeps the tab)
- [x] `tabs.highlight` (selects the first tab given)
- [x] `tabs.getZoomSettings`
- [x] `tabs.setZoomSettings` (`automatic`, `manual`, `disabled` modes; `per-origin` and `per-tab` scopes)
- [x] `tabs.print` (Firefox)
- [x] `tabs.warmup` (Firefox; nothing to do)
- [x] `tabs.captureTab` (Firefox; any loaded tab, `rect` and `scale` honoured)
- [x] `tabs.hide` (Firefox; `tabHide` permission, hides non-active/non-pinned tabs and restores them on unload)
- [x] `tabs.show` (Firefox)
- [x] `tabs.moveInSuccession` (Firefox; `append` and `insert` supported, honoured when closing tabs)
- [x] `tabs.printPreview` (Firefox; the Mac's print panel, which previews)
- [x] `tabs.saveAsPDF` (Firefox; asks where with a save panel)
- [x] `tabs.getAllInWindow` (deprecated)
- [x] `tabs.sendRequest` (deprecated)

## action / browserAction / pageAction

- [x] `action.setBadgeBackgroundColor` is drawn (the badge was always red)
- [x] `action.setBadgeTextColor` (without one, black or white is picked for contrast)
- [x] `action.getBadgeTextColor`
- [x] `action.getUserSettings` (reports whether the button is pinned on the toolbar)
- [x] `action.isEnabled` takes Chrome's plain tab id (WebKit wanted `{ tabId }`)
- [x] `action.onUserSettingsChanged` (fires when the button is pinned or unpinned)
- [x] `pageAction.show` (Firefox; mapped onto enable)
- [x] `pageAction.hide` (Firefox; mapped onto disable)
- [x] `pageAction.isShown` (Firefox)

## runtime

- [x] `runtime.requestUpdateCheck` (installs the update straight away)
- [x] `runtime.getBrowserInfo` (Firefox extensions only; Chrome ones take it to mean Firefox)
- [x] `runtime.getContexts`: background, tabs, side panel, action popup and offscreen document
- [x] `runtime.getPackageDirectoryEntry` (read-only `DirectoryEntry` / `FileEntry` tree over the extension's bundle)
- [ ] `runtime.onSuspend`
- [ ] `runtime.onSuspendCanceled`
- [x] `runtime.onUpdateAvailable` (the update waits for `runtime.reload()` or Tuff's next launch)
- [x] `runtime.onBrowserUpdateAvailable` (when a Tuff update is downloaded and ready)
- [x] `runtime.onUserScriptMessage` (when the user script world has `messaging: true`)
- [x] `runtime.onUserScriptConnect`
- [x] `runtime.onInstalled` (WebKit never fires it for a newly added extension; Tuff sends it)

## extension

- [x] `extension.setUpdateUrlData` (Tuff updates from the stores, so nothing to do)
- [~] `extension.getExtensionTabs`: always `[]`
- [x] `extension.sendRequest` (deprecated; not to other extensions, see below)
- [x] `extension.onRequest` (deprecated)
- [ ] `extension.onRequestExternal` (deprecated; WebKit has no messaging between extensions)

## menus / contextMenus

- [x] `menus.refresh` (WebKit builds the menu as it opens, so nothing to do)
- [x] `menus.getTargetElement` (Firefox)
- [x] `menus.overrideContext` (Firefox; `bookmark` and `tab` contexts with custom and default items)
- [x] `menus.onShown` (Firefox; `ExtensionMenus`)
- [x] `menus.onHidden` (Firefox)

## commands

- [x] `commands.openShortcutSettings` (Firefox; opens Settings → Extensions)
- [x] `commands.update` (Firefox; shortcut and description, kept across launches)
- [x] `commands.reset` (Firefox)

## i18n / cookies / webNavigation / storage

- [x] `i18n.detectLanguage` (Apple's NaturalLanguage; not in content scripts)
- [x] `cookies.getPartitionKey` (`topLevelSite` and `hasCrossSiteAncestor` from the tab's URL)
- [ ] `webNavigation.onTabReplaced` (Tuff doesn't prerender, so mostly moot)
- [~] `storage.sync`: kept on this Mac only, not synced between devices
- [x] `storage.managed` (reads Mozilla / Tuff `ManagedStorage` manifests and macOS managed preferences, with `onChanged`; `ExtensionManagedStorage`)

## identity

- [ ] `identity.getAuthToken` (needs a Google account in the browser, as do the next four)
- [ ] `identity.removeCachedAuthToken`
- [ ] `identity.clearAllCachedAuthTokens`
- [ ] `identity.getProfileUserInfo`
- [ ] `identity.getAccounts`
- [ ] `identity.onSignInChanged`

## downloads

- [x] `downloads.removeFile` (moves the file to the Trash; `onChanged` reports `exists`)
- [x] `downloads.getFileIcon`
- [x] `downloads.showDefaultFolder`
- [x] `downloads.acceptDanger` (Tuff doesn't hold back dangerous files)
- [x] `downloads.setShelfEnabled` (no download shelf)
- [x] `downloads.setUiOptions` (no download shelf)
- [x] `downloads.drag` (starts a native macOS file drag session for the downloaded file)
- [x] `downloads.onDeterminingFilename` (sync and async `suggest({ filename, conflictAction })`, with a 5 s timeout)

## sessions

- [x] `sessions.getDevices`: open tabs on the Firefox account's other devices; `restore` opens them
- [x] `sessions.getTabValue` (Firefox; values outlive a relaunch and follow a reopened tab, `ExtensionSessionValues`)
- [x] `sessions.setTabValue` (Firefox)
- [x] `sessions.removeTabValue` (Firefox)
- [x] `sessions.getWindowValue` (Firefox; Tuff has the one window)
- [x] `sessions.setWindowValue` (Firefox)
- [x] `sessions.removeWindowValue` (Firefox)
- [x] `sessions.forgetClosedTab` (Firefox)
- [x] `sessions.forgetClosedWindow` (Firefox; there are never closed windows, so it always says so)

## browsingData

- [x] `browsingData.removeAppcache`
- [x] `browsingData.removeCacheStorage`
- [x] `browsingData.removeDownloads`
- [x] `browsingData.removeFileSystems`
- [~] `browsingData.removeFormData`: reports success, removes nothing
- [x] `browsingData.removeIndexedDB`
- [x] `browsingData.removePasswords` (removes saved logins in `PasswordStore`, honouring `since` / `origins` / `excludeOrigins`)
- [x] `browsingData.removePluginData` (no plug-ins, so nothing to remove)
- [x] `browsingData.removeServiceWorkers`
- [x] `browsingData.removeWebSQL`

## management

- [x] `management.uninstall` (always asks)
- [x] `management.getPermissionWarningsByManifest`
- [x] `management.getPermissionWarningsById` (returned `[]` before)
- [x] `management.install` (Firefox static theme `.xpi` with optional hash check and confirmation)

## notifications / tts / search

- [x] `notifications.onShowSettings` (Chrome no longer shows the settings button either)
- [x] `notifications.onPermissionLevelChanged`
- [x] `tts.onVoicesChanged`
- [x] `search.search` (Firefox). `search.query` also now uses the current tab by default, as in Chrome.

## system.storage

- [x] `system.storage.ejectDevice` (drives and disk images; never the startup disk)
- [x] `system.storage.getAvailableCapacity`
- [x] `system.storage.onAttached`
- [x] `system.storage.onDetached`
- [x] `system.storage.getInfo` lists every volume the Finder shows, by volume UUID (it was only the startup disk)

## proxy

- [x] `proxy.settings.set` (`direct`, `pac_script`, `auto_detect`, `fixed_servers` including SOCKS4, and Firefox equivalents via local loopback relay; `ExtensionProxy`)
- [x] `proxy.onRequest` (Firefox; dynamic per-request routing with `ProxyInfo` failover)
- [x] `proxy.onProxyError`
- [x] `proxy.onError` (Firefox)

## userScripts

- [x] `userScripts.execute`
- [x] `userScripts.configureWorld` (`worldId` and `messaging`; WebKit has no per-world CSP)
- [x] `userScripts.resetWorldConfiguration`
- [x] `userScripts.getWorldConfigurations`
- [x] `userScripts.onBeforeScript` (Firefox; runs manifest `user_scripts.api_script` with `metadata` and `defineGlobals`)

## contentSettings

- [x] `contentSettings.cookies.set` (per-site and global `allow` / `block` via `WKContentRuleList` + `session_only` cleared on quit)
- [x] `contentSettings.images.set` (per-site and global `allow` / `block` via `WKContentRuleList`)
- [x] `contentSettings.automaticDownloads.set` (per-site and global `allow` / `block` / `ask` via `SiteSettings`)
- [ ] `contentSettings.autoVerify.set`
- [x] `contentSettings.clipboard.set` (per-site and global `allow` / `block` / `ask` via `SiteSettings`)
- [x] `contentSettings.sound.set` (per-site and global muting via `SiteSettings`)
- [~] `contentSettings.*.getResourceIdentifiers`: always nothing

## contextualIdentities / theme / tabGroups

- [x] `contextualIdentities.move`
- [x] `theme.update` (colours, `theme_frame` / `additional_backgrounds` images, and alignment / tiling / `color_scheme` properties)
- [x] `tabGroups.update` (folder colours persist across launches)

## devtools (WebKit's, inside Web Inspector)

- [ ] `devtools.inspectedWindow.getResources`
- [ ] `devtools.inspectedWindow.onResourceAdded`
- [ ] `devtools.inspectedWindow.onResourceContentCommitted`
- [ ] `devtools.network.getHAR`
- [ ] `devtools.network.onRequestFinished`
- [ ] `devtools.panels.elements.createSidebarPane`
- [ ] `devtools.panels.elements.onSelectionChanged`
- [ ] `devtools.panels.sources.createSidebarPane`
- [ ] `devtools.panels.sources.onSelectionChanged`
- [ ] `devtools.panels.setOpenResourceHandler`
- [ ] `devtools.panels.openResource`
- [ ] `devtools.performance.onProfilingStarted`
- [ ] `devtools.performance.onProfilingStopped`
- [ ] `devtools.recorder.createView`
- [ ] `devtools.recorder.registerRecorderExtensionPlugin`

## Won't do (not counted)

These exist only on ChromeOS, only for Chrome Apps, only for Mozilla-signed add-ons, or never
shipped. They're inert where extensions might touch them at startup.

- ChromeOS only: `audio`, `certificateProvider`, `documentScan`, `enterprise.*`, `fileBrowserHandler`,
  `fileSystemProvider`, `input.ime`, `loginState`, `platformKeys`, `printerProvider`, `printing`,
  `printingMetrics`, `systemLog`, `vpnProvider`, `wallpaper`, most of `accessibilityFeatures`,
  `idle.getAutoLockDelay`, `power.reportActivity`, the `system.display` setters and calibration,
  `ttsEngine`'s language-pack events and `sendTtsAudio`
- Chrome Apps: `app.*`, `sockets`, `serial`, `usb`, `bluetooth`, `fileSystem`, `management.launchApp`,
  `createAppShortcut`, `setLaunchType`, `generateAppForLink`
- Dev channel only or never shipped: `processes`, `declarativeWebRequest`
- Firefox privileged: `trial.ml`, `geckoProfiler`, `telemetry`, `normandyAddonStudy`, `urlbar`,
  `activityLog`, `networkStatus`
- Removed from Firefox: `proxy.register` / `unregister`
- ChromeOS kiosk apps only: `runtime.restart`, `runtime.restartAfterDelay`, `runtime.onRestartRequired`

## Known bugs (not counted)

(None currently.)

## Bugs found while doing this (fixed)

- Removing the Fetch cache (`browsingData.removeCache`, `removeCacheStorage`) stopped the calling
  extension's own service worker because `WKWebsiteDataStore.removeData` cleared extension origins
  too. `removeBrowsingData` now filters out installed extension records (and honours `origins` /
  `excludeOrigins`).

- The shim treated every background service worker as an extension frame embedded in a website
  (a worker has no `top`), so MV3 workers got none of Tuff's native APIs: `history`, `notifications`,
  `sidePanel`, `downloads`, `tabGroups` and the rest were missing or inert. This was in the
  uncommitted 1Password change.
- The event relay (`ExtensionEventPush`) delivered only the first event to each extension:
  `evaluateJavaScript` saw `sendMessage`'s promise as the script's result, called that an error,
  and kept reloading and resending the first event.
- WebKit never fires `runtime.onInstalled` for a newly added extension (only `onStartup`, and
  `onInstalled` after a `runtime.reload()`), so extensions that set themselves up there (adding
  declarativeContent rules, opening a welcome page) did nothing on install. Tuff now sends it.
- Tuff's events reach every open page of an extension, not just its background, so the shim's own
  handling of them (declarativeContent's show / hide) ran once per open page. It now runs only in
  the background.
- `tabs.captureVisibleTab` always gave an empty image (`data:,`): WebKit asks Tuff for the snapshot
  with a zero rect, which snapshots nothing. A zero rect now means the whole page.

## Progress

APIs done: 25%, 58/234 (58 new)
APIs done: 33%, 77/235 (19 new)
APIs done: 39%, 90/232 (13 new)
APIs done: 41%, 95/232 (5 new)
APIs done: 55%, 128/232 (33 new)
APIs done: 67%, 155/232 (27 new)
APIs done: 75%, 174/232 (19 new)
