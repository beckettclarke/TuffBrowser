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
- [~] `bookmarks.getRecent`: by position (newest are added last), since Tuff keeps no dates
- [x] `bookmarks.getTree`
- [x] `bookmarks.getSubTree`
- [x] `bookmarks.search`
- [~] `bookmarks.create`: no separators (Firefox `type: "separator"`)
- [x] `bookmarks.update`
- [x] `bookmarks.move`
- [x] `bookmarks.remove`
- [x] `bookmarks.removeTree`
- [x] `bookmarks.onCreated`
- [x] `bookmarks.onRemoved`
- [x] `bookmarks.onChanged`
- [x] `bookmarks.onMoved`
- [ ] `bookmarks.onChildrenReordered`
- [ ] `bookmarks.onImportBegan`
- [ ] `bookmarks.onImportEnded`
- [ ] `BookmarkTreeNode.dateAdded` / `dateGroupModified` (Tuff stores no dates)

## declarativeContent (`ExtensionDeclarativeContent`)

- [x] `declarativeContent.onPageChanged.addRules` (rules are saved across launches)
- [x] `declarativeContent.onPageChanged.removeRules`
- [x] `declarativeContent.onPageChanged.getRules`
- [~] `declarativeContent.PageStateMatcher`: `pageUrl` and `isBookmarked` work; `css` counts as met
- [x] `declarativeContent.ShowAction`
- [x] `declarativeContent.ShowPageAction`
- [ ] `declarativeContent.SetIcon`
- [ ] `declarativeContent.RequestContentScript`

## system.display

- [x] `system.display.getInfo`
- [~] `system.display.getDisplayLayout`: always `[]`
- [ ] `system.display.onDisplayChanged`

## debugger

- [ ] `debugger.attach`
- [ ] `debugger.detach`
- [ ] `debugger.sendCommand`
- [ ] `debugger.getTargets`
- [ ] `debugger.onEvent`
- [ ] `debugger.onDetach`

## pageCapture

- [ ] `pageCapture.saveAsMHTML`

## readingList

- [ ] `readingList.addEntry`
- [ ] `readingList.removeEntry`
- [ ] `readingList.updateEntry`
- [ ] `readingList.query`
- [ ] `readingList.onEntryAdded`
- [ ] `readingList.onEntryRemoved`
- [ ] `readingList.onEntryUpdated`

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

## ttsEngine

- [ ] `ttsEngine.updateVoices`
- [ ] `ttsEngine.sendTtsEvent`
- [ ] `ttsEngine.onSpeak`
- [ ] `ttsEngine.onStop`
- [ ] `ttsEngine.onPause`
- [ ] `ttsEngine.onResume`

## webAuthenticationProxy

- [ ] `webAuthenticationProxy.attach`
- [ ] `webAuthenticationProxy.detach`
- [ ] `webAuthenticationProxy.completeCreateRequest`
- [ ] `webAuthenticationProxy.completeGetRequest`
- [ ] `webAuthenticationProxy.completeIsUvpaaRequest`
- [ ] `webAuthenticationProxy.onCreateRequest`
- [ ] `webAuthenticationProxy.onGetRequest`
- [ ] `webAuthenticationProxy.onIsUvpaaRequest`
- [ ] `webAuthenticationProxy.onRemoteSessionStateChange`
- [ ] `webAuthenticationProxy.onRequestCanceled`

## dns / captivePortal / pkcs11 (Firefox)

- [ ] `dns.resolve`
- [ ] `captivePortal.getState`
- [ ] `captivePortal.getLastChecked`
- [ ] `captivePortal.onStateChanged`
- [ ] `captivePortal.onConnectivityAvailable`
- [ ] `pkcs11.installModule`
- [ ] `pkcs11.uninstallModule`
- [ ] `pkcs11.isModuleInstalled`
- [ ] `pkcs11.getModuleSlots`

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

- [ ] `declarativeNetRequest.updateStaticRules`
- [ ] `declarativeNetRequest.getDisabledRuleIds`
- [ ] `declarativeNetRequest.getAvailableStaticRuleCount`
- [ ] `declarativeNetRequest.testMatchOutcome` (always reports no match)
- [ ] `declarativeNetRequest.onRuleMatchedDebug`
- [~] `declarativeNetRequest.MAX_*` limits: Chrome's figures, not WebKit's

## tabs

- [x] `tabs.discard` (sleeps the tab)
- [x] `tabs.highlight` (selects the first tab given)
- [x] `tabs.getZoomSettings`
- [~] `tabs.setZoomSettings`: only automatic, per-site zoom
- [x] `tabs.print` (Firefox)
- [x] `tabs.warmup` (Firefox; nothing to do)
- [ ] `tabs.captureTab` (Firefox)
- [ ] `tabs.hide` (Firefox)
- [ ] `tabs.show` (Firefox)
- [ ] `tabs.moveInSuccession` (Firefox)
- [ ] `tabs.printPreview` (Firefox)
- [ ] `tabs.saveAsPDF` (Firefox)
- [ ] `tabs.getAllInWindow` (deprecated)
- [ ] `tabs.sendRequest` (deprecated)

## action / browserAction / pageAction

- [x] `action.setBadgeBackgroundColor` is drawn (the badge was always red)
- [x] `action.setBadgeTextColor` (without one, black or white is picked for contrast)
- [x] `action.getBadgeTextColor`
- [x] `action.getUserSettings` (always on the toolbar)
- [x] `action.isEnabled` takes Chrome's plain tab id (WebKit wanted `{ tabId }`)
- [ ] `action.onUserSettingsChanged`
- [x] `pageAction.show` (Firefox; mapped onto enable)
- [x] `pageAction.hide` (Firefox; mapped onto disable)
- [x] `pageAction.isShown` (Firefox)

## runtime

- [x] `runtime.requestUpdateCheck` (installs the update straight away)
- [x] `runtime.getBrowserInfo` (Firefox extensions only; Chrome ones take it to mean Firefox)
- [ ] `runtime.getContexts`
- [ ] `runtime.restart`
- [ ] `runtime.restartAfterDelay`
- [ ] `runtime.getPackageDirectoryEntry`
- [ ] `runtime.onSuspend`
- [ ] `runtime.onSuspendCanceled`
- [ ] `runtime.onUpdateAvailable`
- [ ] `runtime.onRestartRequired`
- [ ] `runtime.onBrowserUpdateAvailable`
- [ ] `runtime.onUserScriptMessage`
- [ ] `runtime.onUserScriptConnect`
- [ ] `runtime.onInstalled`: check it fires; it didn't for a folder install (`installdir`) in a debug run

## extension

- [x] `extension.setUpdateUrlData` (Tuff updates from the stores, so nothing to do)
- [~] `extension.getExtensionTabs`: always `[]`
- [ ] `extension.sendRequest` (deprecated)
- [ ] `extension.onRequest` (deprecated)
- [ ] `extension.onRequestExternal` (deprecated)

## menus / contextMenus

- [x] `menus.refresh` (WebKit builds the menu as it opens, so nothing to do)
- [ ] `menus.getTargetElement` (Firefox)
- [ ] `menus.overrideContext` (Firefox)
- [ ] `menus.onShown` (Firefox)
- [ ] `menus.onHidden` (Firefox)

## commands

- [x] `commands.openShortcutSettings` (Firefox; opens Settings → Extensions)
- [ ] `commands.update` (Firefox)
- [ ] `commands.reset` (Firefox)

## i18n / cookies / webNavigation / storage

- [x] `i18n.detectLanguage` (Apple's NaturalLanguage; not in content scripts)
- [ ] `cookies.getPartitionKey`
- [ ] `webNavigation.onTabReplaced` (Tuff doesn't prerender, so mostly moot)
- [~] `storage.sync`: kept on this Mac only, not synced between devices
- [~] `storage.managed`: always empty (no policies)

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
- [ ] `downloads.drag` (accepted, does nothing)
- [ ] `downloads.onDeterminingFilename`

## sessions

- [x] `sessions.getDevices`: open tabs on the Firefox account's other devices; `restore` opens them
- [ ] `sessions.getTabValue` (Firefox)
- [ ] `sessions.setTabValue` (Firefox)
- [ ] `sessions.removeTabValue` (Firefox)
- [ ] `sessions.getWindowValue` (Firefox)
- [ ] `sessions.setWindowValue` (Firefox)
- [ ] `sessions.removeWindowValue` (Firefox)
- [ ] `sessions.forgetClosedTab` (Firefox)
- [ ] `sessions.forgetClosedWindow` (Firefox)

## browsingData

- [x] `browsingData.removeAppcache`
- [x] `browsingData.removeCacheStorage`
- [x] `browsingData.removeDownloads`
- [x] `browsingData.removeFileSystems`
- [~] `browsingData.removeFormData`: reports success, removes nothing
- [x] `browsingData.removeIndexedDB`
- [~] `browsingData.removePasswords`: reports success, removes nothing (Tuff does save passwords now)
- [x] `browsingData.removePluginData` (no plug-ins, so nothing to remove)
- [x] `browsingData.removeServiceWorkers`
- [x] `browsingData.removeWebSQL`

## management

- [x] `management.uninstall` (always asks)
- [x] `management.getPermissionWarningsByManifest`
- [x] `management.getPermissionWarningsById` (returned `[]` before)
- [ ] `management.install` (Firefox themes)

## notifications / tts / search

- [x] `notifications.onShowSettings` (Chrome no longer shows the settings button either)
- [ ] `notifications.onPermissionLevelChanged`
- [ ] `tts.onVoicesChanged` (inert)
- [x] `search.search` (Firefox). `search.query` also now uses the current tab by default, as in Chrome.

## system.storage

- [ ] `system.storage.ejectDevice`
- [ ] `system.storage.getAvailableCapacity`
- [ ] `system.storage.onAttached`
- [ ] `system.storage.onDetached`

## proxy

- [~] `proxy.settings.set`: no `pac_script` or `auto_detect` modes, no SOCKS4 or QUIC proxies
- [ ] `proxy.onRequest` (Firefox's main proxy API)
- [ ] `proxy.onProxyError`
- [ ] `proxy.onError` (Firefox)

## userScripts

- [ ] `userScripts.execute`
- [~] `userScripts.configureWorld`: accepted, does nothing
- [~] `userScripts.resetWorldConfiguration`: accepted, does nothing
- [~] `userScripts.getWorldConfigurations`: always `[]`
- [ ] `userScripts.onBeforeScript` (Firefox)

## contentSettings

- [ ] `contentSettings.cookies.set`
- [ ] `contentSettings.images.set`
- [ ] `contentSettings.automaticDownloads.set`
- [ ] `contentSettings.autoVerify.set`
- [ ] `contentSettings.clipboard.set`
- [ ] `contentSettings.sound.set`
- [~] `contentSettings.*.getResourceIdentifiers`: always nothing

## contextualIdentities / theme / tabGroups

- [ ] `contextualIdentities.move`
- [~] `theme.update`: only colours apply (as the window tint), no images or properties
- [~] `tabGroups.update`: colours last only for the session

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

## Known bugs (not counted)

- Removing the Fetch cache (`browsingData.removeCache`, `removeCacheStorage`) seems to stop the
  calling extension's own service worker: in a test, nothing after the call ran.

## Bugs found while doing this (fixed)

- The shim treated every background service worker as an extension frame embedded in a website
  (a worker has no `top`), so MV3 workers got none of Tuff's native APIs: `history`, `notifications`,
  `sidePanel`, `downloads`, `tabGroups` and the rest were missing or inert. This was in the
  uncommitted 1Password change.
- The event relay (`ExtensionEventPush`) delivered only the first event to each extension:
  `evaluateJavaScript` saw `sendMessage`'s promise as the script's result, called that an error,
  and kept reloading and resending the first event.

## Progress

APIs done: 25%, 58/234 (58 new)
