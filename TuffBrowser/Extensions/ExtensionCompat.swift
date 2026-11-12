import Foundation

/// Makes store-installed extensions more tolerant of running on WebKit.
///
/// Two kinds of gap are covered by one small script (`shim`) that runs before the extension's
/// own code in every place that code runs — the background worker / page, the extension's
/// HTML pages (popup, options, onboarding…) and its content scripts:
///
/// 1. **Missing APIs.** WebKit implements most of the WebExtensions API, but not a handful of
///    Chrome-only namespaces (`chrome.notifications`, `chrome.identity`, `chrome.offscreen`, …).
///    Extensions usually touch those at the top of their background script — e.g. registering
///    `chrome.notifications.onClicked` — so one missing namespace takes the whole extension
///    down. The shim adds inert stand-ins for whatever is *missing*: events that never fire and
///    methods that resolve to `undefined`.
///
/// 2. **Different behaviour.** WebKit's API functions only work when called *on* their
///    namespace: `const getURL = browser.runtime.getURL; getURL('x')` silently returns
///    `undefined`, where Chrome and Firefox return the URL. Plenty of extensions keep such
///    detached references (uBlock Origin's `vAPI.getURL` is one), so the shim binds every API
///    function to its namespace. It also makes `i18n.getMessage('')` return `''` instead of
///    throwing, and supplies `requestIdleCallback`, which WebKit does not ship.
///
/// Everything WebKit does provide is otherwise left as it is, and the global `chrome` /
/// `browser` objects themselves are never replaced — WebKit looks them up by name to deliver
/// events, so wrapping them silently disconnects every listener.
enum ExtensionCompat {
    static let shimName = "__tuff_compat.js"
    private static let workerName = "__tuff_worker.js"
    /// Records which revision of `patch` an installed extension has had applied. Bump `level`
    /// whenever `patch` learns to hook the shim in somewhere new, so extensions installed by
    /// an older build are brought up to date the next time they load.
    private static let markerName = "__tuff_compat.level"
    private static let level = "2"

    /// The hidden page that opens WebSockets for an extension's service worker (see the shim).
    static let socketRelayPage = "__tuff_socket.html"
    private static let socketRelayScriptName = "__tuff_socket.js"
    private static let socketRelayHTML = "<!doctype html><meta charset=\"utf-8\"><title>Tuff socket relay</title><script src=\"/__tuff_socket.js\"></script>\n"
    private static let socketRelayScript = """
    // Added by Tuff: opens WebSockets on behalf of this extension's background service worker,
    // which WebKit freezes if it opens one itself. See the WebSocket stand-in in __tuff_compat.js.
    (() => {
      const channel = new BroadcastChannel('__tuff_socket_relay');
      const sockets = new Map();
      let current = null;
      const post = (message) => channel.postMessage(message);
      channel.onmessage = (event) => {
        const m = event.data;
        if (!m || typeof m !== 'object' || typeof m.session !== 'string') return;
        if (m.op === 'ping') {
          if (m.session !== current) {
            // A new worker instance: the old one (and its sockets) is gone.
            for (const [key, socket] of sockets) {
              if (!key.startsWith(m.session + ':')) { try { socket.close(); } catch (e) {} sockets.delete(key); }
            }
            current = m.session;
          }
          post({ op: 'ready', session: m.session });
          return;
        }
        const key = m.session + ':' + m.id;
        const reply = (fields) => post(Object.assign({ session: m.session, id: m.id }, fields));
        if (m.op === 'open') {
          let socket;
          try {
            socket = m.protocols && m.protocols.length ? new WebSocket(m.url, m.protocols) : new WebSocket(m.url);
          } catch (e) {
            reply({ op: 'error' });
            reply({ op: 'close', code: 1006, reason: '', wasClean: false });
            return;
          }
          socket.binaryType = 'arraybuffer';
          sockets.set(key, socket);
          socket.onopen = () => reply({ op: 'open', protocol: socket.protocol, extensions: socket.extensions });
          socket.onmessage = (e) => reply({ op: 'message', data: e.data });
          socket.onerror = () => reply({ op: 'error' });
          socket.onclose = (e) => { sockets.delete(key); reply({ op: 'close', code: e.code, reason: e.reason, wasClean: e.wasClean }); };
        } else if (m.op === 'send') {
          const socket = sockets.get(key);
          if (socket && socket.readyState === 1) socket.send(m.data);
        } else if (m.op === 'close') {
          const socket = sockets.get(key);
          if (socket) { try { m.code === undefined ? socket.close() : socket.close(m.code, m.reason); } catch (e) { socket.close(); } }
        }
      };
      post({ op: 'ready' });
    })();
    """

    /// Writes the socket relay page into an extension, if it isn't there or is out of date.
    private static func writeSocketRelay(into root: URL) {
        for (name, text) in [(socketRelayPage, socketRelayHTML), (socketRelayScriptName, socketRelayScript)] {
            let url = root.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Hooks the shim into an unpacked copy of an extension. Safe to run more than once.
    static func patch(extensionAt root: URL) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TUFF_NO_COMPAT"] != nil { return }
        #endif
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any] else { return }

        var changed = false

        if var background = manifest["background"] as? [String: Any] {
            // Manifest V3 service worker.
            if let worker = background["service_worker"] as? String, !worker.contains(workerName) {
                let workerURL = root.appendingPathComponent(worker)
                if (background["type"] as? String) == "module" {
                    // WebKit refuses a wrapper module that imports the real worker, so the shim is
                    // placed at the top of the worker itself (modules are always strict, so this
                    // cannot change how the rest of the file is parsed).
                    if let original = try? Data(contentsOf: workerURL), !original.starts(with: Data(shim.utf8.prefix(40))) {
                        var patched = Data(shim.utf8)
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["TUFF_EXT_DEBUG"] != nil {
                            patched.append(Data(("\n" + debugShim).utf8))
                        }
                        #endif
                        patched.append(Data("\n".utf8))
                        patched.append(original)
                        try? patched.write(to: workerURL, options: .atomic)
                    }
                } else {
                    // Classic worker: a wrapper next to the original (so its relative imports keep
                    // resolving) loads the shim first and leaves the original file byte-for-byte.
                    let wrapperURL = workerURL.deletingLastPathComponent().appendingPathComponent(workerName)
                    let source = "importScripts(\"/\(shimName)\", \"./\(workerURL.lastPathComponent)\");\n"
                    if (try? source.write(to: wrapperURL, atomically: true, encoding: .utf8)) != nil {
                        let directory = (worker as NSString).deletingLastPathComponent
                        background["service_worker"] = directory.isEmpty ? workerName : directory + "/" + workerName
                        changed = true
                    }
                }
            }

            // Manifest V2 / Firefox event pages: the shim simply goes first in the script list.
            // (A background *page* is an HTML file and is handled with the other pages below.)
            if var scripts = background["scripts"] as? [String], !scripts.contains(shimName) {
                scripts.insert(shimName, at: 0)
                background["scripts"] = scripts
                changed = true
            }
            manifest["background"] = background
        }

        // Content scripts: the shim goes first in each isolated-world script list. Scripts
        // that run in the page's own world are left alone — the shim must never leak into
        // websites.
        if var entries = manifest["content_scripts"] as? [[String: Any]] {
            for index in entries.indices {
                guard (entries[index]["world"] as? String)?.uppercased() != "MAIN",
                      var scripts = entries[index]["js"] as? [String], !scripts.isEmpty,
                      !scripts.contains(where: { $0.hasSuffix(shimName) }) else { continue }
                scripts.insert(shimName, at: 0)
                entries[index]["js"] = scripts
                changed = true
            }
            manifest["content_scripts"] = entries
        }

        // HTML pages (background page, popup, options, onboarding…): a script tag ahead of the
        // page's first script. `script-src 'self'`, which every extension page allows, covers it.
        let tag = "<script src=\"/\(shimName)\"></script>\n"
        if let files = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files where ["html", "htm"].contains(file.pathExtension.lowercased()) {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000_000,
                      var html = try? String(contentsOf: file, encoding: .utf8), !html.contains(shimName),
                      let first = html.range(of: "<script", options: .caseInsensitive) else { continue }
                html.insert(contentsOf: tag, at: first.lowerBound)
                try? html.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        writeSocketRelay(into: root)
        guard (try? shim.write(to: root.appendingPathComponent(shimName), atomically: true, encoding: .utf8)) != nil else { return }
        if changed {
            guard let output = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  (try? output.write(to: manifestURL, options: .atomic)) != nil else { return }
        }
        try? level.write(to: root.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
    }

    /// Brings an already-installed extension up to the current shim. Extensions are patched
    /// at install time, so without this an improved shim would only reach them when they are
    /// next updated from the store.
    static func refresh(extensionAt root: URL) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TUFF_NO_COMPAT"] != nil { return }
        #endif
        let fm = FileManager.default

        // Installed by a build whose `patch` hooked the shim into fewer places: patch again.
        if (try? String(contentsOf: root.appendingPathComponent(markerName), encoding: .utf8)) != level {
            patch(extensionAt: root)
        }

        writeSocketRelay(into: root)

        // Everything except module workers loads the shim from its own file.
        let shimURL = root.appendingPathComponent(shimName)
        if fm.fileExists(atPath: shimURL.path), (try? String(contentsOf: shimURL, encoding: .utf8)) != shim {
            try? shim.write(to: shimURL, atomically: true, encoding: .utf8)
        }

        // Module workers carry the shim inline, at the top of the worker file.
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any],
              let background = manifest["background"] as? [String: Any],
              (background["type"] as? String) == "module",
              let worker = background["service_worker"] as? String else { return }
        let workerURL = root.appendingPathComponent(worker)
        guard let source = try? Data(contentsOf: workerURL),
              source.starts(with: Data(shim.utf8.prefix(40))),   // has a shim…
              !source.starts(with: Data(shim.utf8)),              // …but not this one
              let end = source.range(of: Data("\n})();\n".utf8)) else { return }
        var patched = Data(shim.utf8)
        patched.append(Data("\n".utf8))
        patched.append(source[end.upperBound...])
        try? patched.write(to: workerURL, options: .atomic)
    }

    #if DEBUG
    /// Test-only: forwards the background script's console output and uncaught errors to the
    /// app (via a fake native-messaging host name) so automated runs can see what went wrong.
    private static let debugShim = """
    (() => {
      const send = (level, args) => {
        try {
          const text = args.map((a) => {
            if (a instanceof Error) return a.name + ': ' + a.message + ' @ ' + String(a.stack || '').split('\\n').slice(0, 3).join(' | ');
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          }).join(' ').slice(0, 700);
          const p = chrome.runtime.sendNativeMessage('tuff.debug', { level, text });
          if (p && p.catch) p.catch(() => {});
        } catch (e) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level].bind(console);
        console[level] = (...args) => { send(level, args); return original(...args); };
      }
      self.addEventListener('error', (e) => send('uncaught', [e.message, e.filename + ':' + e.lineno + ':' + e.colno]));
      self.addEventListener('unhandledrejection', (e) => send('unhandled', [e.reason]));
      // Which messages and ports reach the background (names only, never contents).
      try {
        chrome.runtime.onMessage.addListener((m, sender) => {
          send('msg', ['onMessage <' + String(m && m.name) + '> from ' + String(sender && sender.url || '-').slice(0, 90) + ' frame=' + (sender && sender.frameId)]);
          return false;
        });
        chrome.runtime.onConnect.addListener((p) => send('msg', ['onConnect ' + String(p.name).slice(0, 120)]));
      } catch (e) { send('msg', ['could not watch messages: ' + e]); }
      send('boot', ['debug shim active']);
    })();
    """
    #endif

    /// Note for editors: the first 40 bytes identify the shim inside module workers, and the
    /// only line that may read exactly `})();` is the last one — `refresh` relies on both.
    private static let shim = """
    // Added by Tuff: inert stand-ins for extension APIs that WebKit does not provide,
    // plus fixes for a few places where WebKit behaves differently from Chrome and Firefox.
    (() => {
      const scope = typeof globalThis !== 'undefined' ? globalThis : self;
      // Several content scripts of one extension share a world; once is enough.
      if (scope.__tuffCompat) return;

      // Extension pages and the background context get the full API in Chrome; content
      // scripts only ever see a small part of it, so they get the fixes but no stand-ins.
      let privileged = false;
      try { privileged = /-extension:$/.test(scope.location.protocol); } catch (e) {}

      // Chrome-only namespaces. Each is added only if WebKit has nothing under that name.
      const missing = [
        'notifications', 'identity', 'offscreen', 'tabGroups', 'management', 'privacy', 'idle',
        'system', 'power', 'gcm', 'instanceID', 'tts', 'ttsEngine', 'fontSettings', 'contentSettings',
        'browsingData', 'pageCapture', 'proxy', 'sessions', 'topSites', 'omnibox', 'history', 'bookmarks',
        'downloads', 'debugger', 'enterprise', 'readingList', 'search', 'webAuthenticationProxy', 'loginState',
        'documentScan', 'printing', 'vpnProvider', 'wallpaper', 'certificateProvider', 'platformKeys', 'userScripts',
        // Firefox-only.
        'contentScripts', 'dns', 'browserSettings', 'theme', 'contextualIdentities', 'find',
        'captivePortal', 'networkStatus', 'pkcs11', 'clipboard'
      ];

      // Methods that are missing from namespaces WebKit otherwise has. Only ones whose result
      // callers ignore belong here — anything else is better left undefined, so that
      // extensions which test for it take their fallback path.
      const methods = {
        webRequest: ['handlerBehaviorChanged'],
      };

      // Events Chrome has that WebKit may not, inside namespaces that otherwise exist.
      const events = {
        webNavigation: ['onCreatedNavigationTarget', 'onTabReplaced', 'onHistoryStateUpdated', 'onReferenceFragmentUpdated',
          'onBeforeNavigate', 'onCommitted', 'onDOMContentLoaded', 'onCompleted', 'onErrorOccurred'],
        tabs: ['onZoomChange', 'onHighlighted', 'onAttached', 'onDetached', 'onMoved', 'onReplaced', 'onActivated',
          'onUpdated', 'onCreated', 'onRemoved'],
        windows: ['onBoundsChanged', 'onFocusChanged', 'onCreated', 'onRemoved'],
        runtime: ['onSuspend', 'onSuspendCanceled', 'onUpdateAvailable', 'onRestartRequired', 'onConnectExternal',
          'onMessageExternal', 'onBrowserUpdateAvailable', 'onStartup', 'onInstalled', 'onUserScriptMessage',
          'onUserScriptConnect', 'onConnectNative'],
        webRequest: ['onAuthRequired', 'onBeforeRedirect', 'onBeforeRequest', 'onBeforeSendHeaders', 'onCompleted',
          'onErrorOccurred', 'onHeadersReceived', 'onResponseStarted', 'onSendHeaders', 'onActionIgnored'],
        action: ['onClicked', 'onUserSettingsChanged'],
        browserAction: ['onClicked'],
        pageAction: ['onClicked'],
        permissions: ['onAdded', 'onRemoved'],
        storage: ['onChanged'],
        cookies: ['onChanged'],
        commands: ['onCommand', 'onChanged'],
        alarms: ['onAlarm'],
        contextMenus: ['onClicked'],
        menus: ['onClicked', 'onShown', 'onHidden'],
        declarativeNetRequest: ['onRuleMatchedDebug'],
        extension: ['onRequest', 'onRequestExternal'],
      };

      // Inert stand-in: any property is another stand-in; calling a method resolves to
      // undefined (or invokes a trailing callback with no arguments); events never fire.
      const stub = (path, isEvent) => new Proxy(function () {}, {
        get(_, prop) {
          if (typeof prop === 'symbol' || prop === 'then' || prop === 'toJSON') return undefined;
          return stub(path + '.' + prop, isEvent || /^on[A-Z]/.test(prop));
        },
        apply(_, __, args) {
          if (isEvent) return /\\.hasListeners?$/.test(path) ? false : undefined;
          const last = args.length ? args[args.length - 1] : undefined;
          if (typeof last === 'function') {
            try { last(); } catch (e) {}
            return undefined;
          }
          return Promise.resolve(undefined);
        }
      });

      // `storage.managed` (enterprise policy) is read at startup by many extensions; with no
      // policy it is simply empty.
      const answer = (value) => (keys, callback) => {
        const done = typeof keys === 'function' ? keys : callback;
        if (typeof done === 'function') { done(value); return undefined; }
        return Promise.resolve(value);
      };
      const objects = {
        storage: {
          managed: (path) => ({
            get: answer({}),
            getBytesInUse: answer(0),
            getKeys: answer([]),
            onChanged: stub(path + '.onChanged', true),
          }),
        },
      };

      const absent = (object, name) => {
        try { return object[name] === undefined || object[name] === null; } catch (e) { return false; }
      };
      const add = (object, name, value) => {
        try { Object.defineProperty(object, name, { value, configurable: true, writable: true, enumerable: false }); } catch (e) {}
        try { if (object[name] !== value) object[name] = value; } catch (e) {}
      };

      // Important: the global `chrome` / `browser` objects are never replaced or wrapped.
      // WebKit finds them by name to deliver events, so swapping them silently breaks every
      // listener. Changes are instead made on the real namespace objects. WebKit hands those
      // out (chrome.storage, chrome.runtime.onMessage, …) from a weak cache, so the ones we
      // change are kept referenced here — otherwise the changes vanish at the next garbage
      // collection.
      const pins = [];
      const roots = [];
      for (const label of ['chrome', 'browser']) {
        let root;
        try { root = scope[label]; } catch (e) { continue; }
        if (root && (typeof root === 'object' || typeof root === 'function') && !roots.some((r) => r.root === root)) {
          roots.push({ root, label });
        }
      }

      // WebKit's API functions return undefined when called off their namespace
      // (`const { getURL } = chrome.runtime`), which Chrome and Firefox both allow. Bind each
      // one to the object it came from: namespaces, then what hangs off them (storage areas,
      // events). This runs before any stand-ins exist, so it only ever touches the real API.
      const visited = new Set();
      const bindAll = (object, depth) => {
        if (!object || typeof object !== 'object' || visited.has(object) || Array.isArray(object)) return;
        visited.add(object);
        const names = new Set();
        try {
          for (let o = object; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
            for (const name of Object.getOwnPropertyNames(o)) names.add(name);
          }
        } catch (e) { return; }
        names.delete('constructor');
        let touched = false;
        for (const name of names) {
          let value;
          try { value = object[name]; } catch (e) { continue; }
          if (typeof value === 'function') {
            add(object, name, value.bind(object));
            touched = true;
          } else if (depth > 0) {
            bindAll(value, depth - 1);
          }
        }
        if (touched) pins.push(object);
      };
      for (const { root } of roots) bindAll(root, 3);

      // Chrome and Firefox answer '' for an empty or unknown message name; WebKit throws.
      for (const { root } of roots) {
        let i18n;
        try { i18n = root.i18n; } catch (e) { continue; }
        if (!i18n || typeof i18n.getMessage !== 'function') continue;
        const getMessage = i18n.getMessage;
        add(i18n, 'getMessage', (name, substitutions) => {
          if (typeof name !== 'string' || name === '') return '';
          try {
            const text = substitutions === undefined ? getMessage(name) : getMessage(name, substitutions);
            return typeof text === 'string' ? text : '';
          } catch (e) { return ''; }
        });
        pins.push(i18n);
      }

      // Chrome accepts `tabs.sendMessage(tab, msg, { frameId, documentId })` (the two just have to
      // agree); WebKit throws "cannot specify both". 1Password always passes both when it has
      // them, so its replies to the 1Password website were lost. A document ID already names one
      // frame, so keep that and drop the frame ID.
      for (const { root } of roots) {
        let tabs;
        try { tabs = root.tabs; } catch (e) { continue; }
        if (!tabs || typeof tabs.sendMessage !== 'function') continue;
        const sendMessage = tabs.sendMessage;
        add(tabs, 'sendMessage', (...args) => {
          const options = args[2];
          if (options && typeof options === 'object' && options.documentId !== undefined && options.frameId !== undefined) {
            const { frameId, ...rest } = options;
            args[2] = rest;
          }
          return sendMessage(...args);
        });
        pins.push(tabs);
      }

      // WebKit throws, synchronously, when permissions.contains / request / remove names a
      // permission it does not know (clipboardRead, say); Chrome and Firefox answer. Thrown at
      // the top of a module, that stops the whole page. A permission WebKit does not know is
      // one the extension can never hold: `contains` answers false, and `request` / `remove`
      // go ahead with the rest and answer false (Chrome's answer when not all were granted).
      const unknownPermission = (error) => {
        const match = /'([^']+)' is not a valid permission/.exec(String((error && error.message) || ''));
        return match ? match[1] : null;
      };
      for (const { root } of roots) {
        let permissions;
        try { permissions = root.permissions; } catch (e) { continue; }
        if (!permissions || typeof permissions !== 'object') continue;
        let touched = false;
        for (const name of ['contains', 'request', 'remove']) {
          const original = permissions[name];
          if (typeof original !== 'function' || original.__tuff) continue;
          const tolerant = (details, ...rest) => {
            try { return original(details, ...rest); } catch (error) {
              let unknown = unknownPermission(error);
              if (!unknown || !details || !Array.isArray(details.permissions)) throw error;
              const callback = typeof rest[rest.length - 1] === 'function' ? rest[rest.length - 1] : null;
              const answer = (value) => {
                if (!callback) return Promise.resolve(value);
                try { callback(value); } catch (e) {}
                return undefined;
              };
              if (name === 'contains') return answer(false);
              const origins = Array.isArray(details.origins) ? details.origins : [];
              let known = details.permissions;
              while (unknown) {
                const drop = unknown;
                known = known.filter((p) => p !== drop);
                if (!known.length && !origins.length) return answer(false);
                try {
                  const result = original(Object.assign({}, details, { permissions: known }));
                  return Promise.resolve(result).then(() => answer(false), () => answer(false));
                } catch (again) {
                  unknown = unknownPermission(again);
                  if (!unknown) throw again;
                }
              }
              return answer(false);
            }
          };
          tolerant.__tuff = true;
          add(permissions, name, tolerant);
          touched = true;
        }
        if (touched) pins.push(permissions);
      }

      // WebKit rejects a context-menu item outright when one of its `targetUrlPatterns` uses a
      // scheme it does not know (uBlock Origin's `abp:*`), and the exception usually aborts the
      // loop creating the extension's other items. Drop just the patterns WebKit cannot match.
      for (const { root } of roots) {
        for (const name of ['contextMenus', 'menus']) {
          let menus;
          try { menus = root[name]; } catch (e) { continue; }
          if (!menus || typeof menus.create !== 'function' || menus.create.__tuff) continue;
          const create = menus.create;
          const tolerant = (properties, ...rest) => {
            try { return create(properties, ...rest); } catch (error) {
              const patterns = properties && properties.targetUrlPatterns;
              if (!Array.isArray(patterns)) throw error;
              const usable = patterns.filter((p) => /^(\\*|https?|wss?|file|ftp):\\/\\//.test(p) || p === '<all_urls>');
              if (usable.length === patterns.length) throw error;
              if (!usable.length) return properties.id;
              return create({ ...properties, targetUrlPatterns: usable }, ...rest);
            }
          };
          tolerant.__tuff = true;
          add(menus, 'create', tolerant);
          pins.push(menus);
        }
      }

      // WebKit has no requestIdleCallback; "soon" is close enough.
      if (typeof scope.requestIdleCallback !== 'function' && typeof scope.setTimeout === 'function') {
        scope.requestIdleCallback = (callback) => scope.setTimeout(() => {
          const start = Date.now();
          callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
        }, 1);
        scope.cancelIdleCallback = (id) => scope.clearTimeout(id);
      }

      // Side panels: chrome.sidePanel and Firefox's browser.sidebarAction. WebKit has neither;
      // Tuff shows the panel itself (Extensions/SidePanels.swift). A call travels as
      // tabs.create() with a private URL, which Tuff intercepts — no tab opens — and answers by
      // failing with a marked reply. tabs.create is the one browser call every extension
      // context, service workers included, can make without asking for a permission.
      if (privileged) {
        for (const { root, label } of roots) {
          let tabs;
          try { tabs = root.tabs; } catch (e) { continue; }
          if (!tabs || typeof tabs.create !== 'function') continue;
          const create = tabs.create;
          const get = typeof tabs.get === 'function' ? tabs.get : null;
          const marker = '__tuff_sidepanel__:';
          const call = async (op, details) => {
            const args = Object.assign({}, details && typeof details === 'object' ? details : {});
            if (args.tabId !== undefined && args.tabId !== null) {
              let tab = null;
              try { tab = get ? await get(args.tabId) : null; } catch (e) {}
              if (!tab) throw new Error('No tab with id: ' + args.tabId + '.');
              args.tabIndex = tab.index;
            }
            const url = 'tuff-sidepanel://' + op + '/?d=' + encodeURIComponent(JSON.stringify(args));
            try {
              await create({ url, active: false });
            } catch (error) {
              const text = String((error && error.message) || error);
              const at = text.indexOf(marker);
              if (at < 0) throw error;
              let reply = {};
              try { reply = JSON.parse(text.slice(at + marker.length, text.lastIndexOf('}') + 1)); } catch (e) {}
              if (reply.error) throw new Error(reply.error);
              return reply.value === null ? undefined : reply.value;
            }
            return undefined;
          };
          // Promise style, or a trailing callback like the rest of chrome.*.
          const api = (impl) => function (...args) {
            const callback = args.length && typeof args[args.length - 1] === 'function' ? args.pop() : null;
            const promise = Promise.resolve().then(() => impl(...args));
            if (!callback) return promise;
            promise.then((value) => { try { callback(value); } catch (e) {} }, () => { try { callback(); } catch (e) {} });
            return undefined;
          };
          // Anything not implemented (onOpened, onClosed, …) is an inert stand-in.
          const namespace = (name, methods) => new Proxy(methods, {
            get(target, prop) {
              if (typeof prop === 'symbol' || Object.prototype.hasOwnProperty.call(target, prop)) return target[prop];
              if (prop === 'then' || prop === 'toJSON') return undefined;
              return stub(label + '.' + name + '.' + prop, /^on[A-Z]/.test(prop));
            }
          });
          if (absent(root, 'sidePanel')) {
            add(root, 'sidePanel', namespace('sidePanel', {
              open: api((options) => call('open', options)),
              close: api((options) => call('close', options)),
              setOptions: api((options) => call('setOptions', options)),
              getOptions: api((options) => call('getOptions', options)),
              setPanelBehavior: api((behavior) => call('setPanelBehavior', behavior)),
              getPanelBehavior: api(() => call('getPanelBehavior')),
              getLayout: api(() => ({ side: 'right' })),
              setLayout: api(() => undefined),
            }));
          }
          if (absent(root, 'sidebarAction')) {
            add(root, 'sidebarAction', namespace('sidebarAction', {
              open: api(() => call('open')),
              close: api(() => call('close')),
              toggle: api(() => call('toggle')),
              isOpen: api((details) => call('isOpen', details)),
              setPanel: api((details) => call('setPanel', details)),
              getPanel: api((details) => call('getPanel', details)),
              setTitle: api((details) => call('setTitle', details)),
              getTitle: api((details) => call('getTitle', details)),
              setIcon: api(() => undefined),
            }));
          }
        }
      }

      for (const { root, label } of roots) {
        if (privileged) {
          for (const name of missing) {
            if (absent(root, name)) add(root, name, stub(label + '.' + name, false));
          }
        }
        for (const name of new Set([...Object.keys(events), ...Object.keys(methods), ...Object.keys(objects)])) {
          let namespace;
          try { namespace = root[name]; } catch (e) { continue; }
          if (!namespace || typeof namespace !== 'object') continue;
          let touched = false;
          for (const event of (privileged && events[name]) || []) {
            if (absent(namespace, event)) { add(namespace, event, stub(label + '.' + name + '.' + event, true)); touched = true; }
          }
          for (const method of (privileged && methods[name]) || []) {
            if (absent(namespace, method)) { add(namespace, method, stub(label + '.' + name + '.' + method, false)); touched = true; }
          }
          for (const key of Object.keys(objects[name] || {})) {
            if (absent(namespace, key)) { add(namespace, key, objects[name][key](label + '.' + name + '.' + key)); touched = true; }
          }
          if (touched) pins.push(namespace);
        }
      }
      // WebKit deadlocks an extension's background service worker the moment it calls
      // `new WebSocket(…)`: the constructor never returns, and nothing in that worker runs
      // again (not even timers that were already scheduled). 1Password opens one right after
      // you sign in, so it froze before adding the account. In service workers, WebSocket is
      // replaced with a stand-in that relays through a hidden page of the same extension
      // (__tuff_socket.html, started by Tuff on request), where real WebSockets work. The two
      // talk over a BroadcastChannel, which both share as the same origin.
      if (privileged && typeof ServiceWorkerGlobalScope !== 'undefined' && scope instanceof ServiceWorkerGlobalScope
          && typeof BroadcastChannel === 'function') {
        const channel = new BroadcastChannel('__tuff_socket_relay');
        const session = Math.random().toString(36).slice(2) + Date.now().toString(36);
        const sockets = new Map();
        let nextId = 1;
        let relay = null;
        const whenRelayReady = () => {
          if (relay) return relay;
          relay = new Promise((resolve) => {
            let timer = null;
            const ping = () => channel.postMessage({ op: 'ping', session });
            const onReady = (event) => {
              const m = event.data;
              if (!m || m.op !== 'ready' || (m.session && m.session !== session)) return;
              channel.removeEventListener('message', onReady);
              clearInterval(timer);
              resolve();
            };
            channel.addEventListener('message', onReady);
            try {
              const asked = chrome.runtime.sendNativeMessage('tuff.socketrelay', {});
              if (asked && asked.then) asked.then(ping, ping);
            } catch (e) {}
            ping();
            timer = setInterval(ping, 400);
          });
          return relay;
        };
        const makeEvent = (type, fields) => {
          let event;
          if (type === 'message' && typeof MessageEvent === 'function') event = new MessageEvent('message', fields);
          else if (type === 'close' && typeof CloseEvent === 'function') event = new CloseEvent('close', fields);
          else {
            event = new Event(type);
            for (const key of Object.keys(fields || {})) {
              try { Object.defineProperty(event, key, { value: fields[key], enumerable: true }); } catch (e) {}
            }
          }
          return event;
        };
        const fire = (socket, event) => {
          const handler = socket['on' + event.type];
          if (typeof handler === 'function') {
            try { handler.call(socket, event); } catch (e) { setTimeout(() => { throw e; }, 0); }
          }
          socket.dispatchEvent(event);
        };

        class WebSocket extends EventTarget {
          constructor(url, protocols) {
            super();
            let parsed;
            try { parsed = new URL(String(url), scope.location.href); } catch (e) {
              throw new DOMException("Failed to construct 'WebSocket': The URL '" + url + "' is invalid.", 'SyntaxError');
            }
            if (parsed.protocol === 'http:') parsed.protocol = 'ws:';
            if (parsed.protocol === 'https:') parsed.protocol = 'wss:';
            if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
              throw new DOMException("Failed to construct 'WebSocket': The URL's scheme must be either 'ws' or 'wss'.", 'SyntaxError');
            }
            parsed.hash = '';
            this.url = parsed.href;
            this.readyState = 0;
            this.protocol = '';
            this.extensions = '';
            this.bufferedAmount = 0;
            this.binaryType = 'blob';
            this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
            this._id = nextId++;
            sockets.set(this._id, this);
            const list = protocols === undefined ? [] : [].concat(protocols).map(String);
            whenRelayReady().then(() => {
              channel.postMessage({ op: 'open', session, id: this._id, url: this.url, protocols: list });
            });
          }
          send(data) {
            if (this.readyState === 0) throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError');
            if (this.readyState !== 1) return;
            let payload = data;
            if (ArrayBuffer.isView(data)) payload = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
            else if (!(data instanceof ArrayBuffer) && !(typeof Blob === 'function' && data instanceof Blob)) payload = String(data);
            channel.postMessage({ op: 'send', session, id: this._id, data: payload });
          }
          close(code, reason) {
            if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
              throw new DOMException("Failed to execute 'close' on 'WebSocket': The close code must be either 1000, or between 3000 and 4999.", 'InvalidAccessError');
            }
            if (this.readyState >= 2) return;
            this.readyState = 2;
            whenRelayReady().then(() => channel.postMessage({ op: 'close', session, id: this._id, code, reason }));
          }
        }
        for (const [name, value] of [['CONNECTING', 0], ['OPEN', 1], ['CLOSING', 2], ['CLOSED', 3]]) {
          Object.defineProperty(WebSocket, name, { value, enumerable: true });
          Object.defineProperty(WebSocket.prototype, name, { value, enumerable: true });
        }

        channel.addEventListener('message', (event) => {
          const m = event.data;
          if (!m || m.session !== session) return;
          const socket = sockets.get(m.id);
          if (!socket) return;
          if (m.op === 'open') {
            socket.readyState = 1;
            socket.protocol = m.protocol || '';
            socket.extensions = m.extensions || '';
            fire(socket, makeEvent('open'));
          } else if (m.op === 'message') {
            let data = m.data;
            if (socket.binaryType === 'blob' && data instanceof ArrayBuffer && typeof Blob === 'function') data = new Blob([data]);
            let origin = '';
            try { origin = new URL(socket.url).origin; } catch (e) {}
            fire(socket, makeEvent('message', { data, origin }));
          } else if (m.op === 'error') {
            fire(socket, makeEvent('error'));
          } else if (m.op === 'close') {
            socket.readyState = 3;
            sockets.delete(m.id);
            fire(socket, makeEvent('close', { code: m.code || 1006, reason: m.reason || '', wasClean: !!m.wasClean }));
          }
        });
        add(scope, 'WebSocket', WebSocket);
      }
      try { Object.defineProperty(scope, '__tuffCompat', { value: pins, configurable: true }); } catch (e) {}
    })();
    """
}
