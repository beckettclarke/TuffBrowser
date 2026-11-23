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
    private static let level = "4"

    /// The hidden page that opens WebSockets for an extension's service worker (see the shim).
    static let socketRelayPage = "__tuff_socket.html"
    /// The hidden page Tuff scripts to push native-API events into an extension (see ExtensionEventPush).
    static let eventRelayPage = "__tuff_events.html"
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

    /// Undoes what an earlier development build of Tuff did to uBlock Origin (a hidden page
    /// that exported its filters, and a version tweak), now that blocking is Tuff's own.
    private static func removeUBlockLeftovers(from root: URL) {
        for name in ["__tuff_ubo.html", "__tuff_ubo.js"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        let vapiURL = root.appendingPathComponent("js/vapi-common.js")
        if let source = try? String(contentsOf: vapiURL, encoding: .utf8), source.contains("|| 128; // Tuff") {
            try? source.replacingOccurrences(of: "|| 128; // Tuff", with: "|| 120;").write(to: vapiURL, atomically: true, encoding: .utf8)
        }
    }

    /// Writes the event relay page into an extension, if it isn't there or is out of date.
    private static func writeEventRelay(into root: URL) {
        let url = root.appendingPathComponent(eventRelayPage)
        let text = "<!doctype html><meta charset=\"utf-8\"><title>Tuff event relay</title>\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try? text.write(to: url, atomically: true, encoding: .utf8)
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
                    if let original = try? Data(contentsOf: workerURL), !hasModuleShim(original) {
                        var patched = Data(moduleShim.utf8)
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
                      var html = try? String(contentsOf: file, encoding: .utf8), !html.contains(shimName) else { continue }
                html.insert(contentsOf: tag, at: shimInsertionPoint(in: html))
                try? html.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        writeSocketRelay(into: root)
        writeEventRelay(into: root)
        guard (try? shim.write(to: root.appendingPathComponent(shimName), atomically: true, encoding: .utf8)) != nil else { return }
        if changed {
            guard let output = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  (try? output.write(to: manifestURL, options: .atomic)) != nil else { return }
        }
        try? level.write(to: root.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
    }

    /// Where the shim's script tag goes in an extension page: ahead of its first script, or —
    /// for a page with none written in (its scripts may be added later, or it is only framed
    /// by another page) — at the end of `<head>`, the start of `<body>`, or the top.
    static func shimInsertionPoint(in html: String) -> String.Index {
        if let first = html.range(of: "<script", options: .caseInsensitive) { return first.lowerBound }
        if let head = html.range(of: "</head", options: .caseInsensitive) { return head.lowerBound }
        if let body = html.range(of: "<body", options: .caseInsensitive) { return body.lowerBound }
        if let doctype = html.range(of: "<!doctype[^>]*>", options: [.caseInsensitive, .regularExpression]) { return doctype.upperBound }
        return html.startIndex
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
        writeEventRelay(into: root)
        removeUBlockLeftovers(from: root)

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
              hasModuleShim(source),                         // has a shim…
              !source.starts(with: Data(moduleShim.utf8)) else { return }   // …but not this one
        // The shim ends at the end sentinel. Workers patched before there was one end at the
        // shim's last line, the first that reads exactly `})();`.
        let end = source.range(of: Data(moduleEnd.utf8)) ?? source.range(of: Data("\n})();\n".utf8))
        guard let end else { return }
        var patched = Data(moduleShim.utf8)
        var rest = source[end.upperBound...]
        if rest.first == UInt8(ascii: "\n") { rest = rest.dropFirst() }
        patched.append(Data("\n".utf8))
        patched.append(rest)
        try? patched.write(to: workerURL, options: .atomic)
    }

    /// Markers around the copy of the shim at the top of a module worker, so it can be found
    /// and replaced exactly when the shim changes (whatever the shim's text looks like).
    private static let moduleStart = "// __tuff_compat_start__ (added by Tuff; replaced on update)\n"
    private static let moduleEnd = "\n// __tuff_compat_end__\n"
    private static var moduleShim: String { moduleStart + shim + moduleEnd }

    /// Whether a module worker already starts with a copy of the shim (any version).
    private static func hasModuleShim(_ source: Data) -> Bool {
        source.starts(with: Data(moduleStart.utf8)) || source.starts(with: Data(shim.utf8.prefix(40)))
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

    /// Note for editors: module workers find their copy of the shim by `moduleStart` /
    /// `moduleEnd`. (Workers patched by older builds are found by the first 40 bytes and the
    /// first line reading exactly `})();`, so keep the opening line and that rule as they are.)
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
      // An extension page in a frame inside a website (1Password's fill menu) runs in that
      // website's web process. WebKit kills the process if it calls an API only extension pages
      // may use (tabs.query, tabs.create…), and Tuff then reloads the site, losing what was typed.
      // Such frames get inert stand-ins and nothing from the shim that calls the browser.
      let embedded = false;
      // Only pages have a `top`; a background service worker has none and is never embedded.
      if (privileged && scope.top) {
        try { embedded = scope.top !== scope && !/-extension:$/.test(scope.top.location.protocol); } catch (e) { embedded = true; }
      }

      // Chrome-only namespaces. Each is added only if WebKit has nothing under that name.
      const missing = [
        'tabGroups', 'privacy',
        'gcm', 'instanceID', 'ttsEngine', 'fontSettings', 'contentSettings',
        'pageCapture', 'proxy', 'omnibox', 'bookmarks',
        'debugger', 'enterprise', 'readingList', 'webAuthenticationProxy', 'loginState',
        'documentScan', 'printing', 'vpnProvider', 'wallpaper', 'certificateProvider', 'platformKeys', 'userScripts',
        'declarativeContent', 'desktopCapture', 'tabCapture', 'accessibilityFeatures', 'processes', 'printerProvider',
        'printingMetrics', 'systemLog', 'audio', 'fileBrowserHandler', 'fileSystemProvider', 'input', 'declarativeWebRequest',
        // Firefox-only.
        'contentScripts', 'dns', 'browserSettings', 'theme', 'contextualIdentities', 'find',
        'captivePortal', 'networkStatus', 'pkcs11', 'clipboard'
      ];

      // Methods that are missing from namespaces WebKit otherwise has. Only ones whose result
      // callers ignore belong here — anything else is better left undefined, so that
      // extensions which test for it take their fallback path.
      const methods = {
        webRequest: ['handlerBehaviorChanged'],
        menus: ['refresh'],
        extension: ['setUpdateUrlData'],
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
      const constant = (value) => () => value;
      const objects = {
        storage: {
          managed: (path) => ({
            get: answer({}),
            getBytesInUse: answer(0),
            getKeys: answer([]),
            onChanged: stub(path + '.onChanged', true),
          }),
        },
        // Chrome's published limits, for extensions that size their rule sets by them (WebKit
        // leaves them undefined, and `n < undefined` is always false).
        declarativeNetRequest: {
          MAX_NUMBER_OF_DYNAMIC_RULES: constant(30000),
          MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: constant(5000),
          MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: constant(5000),
          MAX_NUMBER_OF_SESSION_RULES: constant(5000),
          MAX_NUMBER_OF_UNSAFE_SESSION_RULES: constant(5000),
          MAX_NUMBER_OF_REGEX_RULES: constant(1000),
          MAX_NUMBER_OF_STATIC_RULESETS: constant(100),
          MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: constant(50),
          MAX_NUMBER_OF_DISABLED_STATIC_RULES: constant(5000),
          GUARANTEED_MINIMUM_STATIC_RULES: constant(30000),
          GETMATCHEDRULES_QUOTA_INTERVAL: constant(10),
          MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: constant(20),
          DYNAMIC_RULESET_ID: constant('_dynamic'),
          SESSION_RULESET_ID: constant('_session'),
        },
        // Legacy (MV2) and synchronous: the extension's own open pages. Never more than none
        // that the caller could script directly in WebKit, so an empty list.
        extension: {
          getExtensionTabs: () => () => [],
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

      // Chrome's first messaging API (Manifest V2, long deprecated, still used by old extensions):
      // extension.sendRequest / onRequest and tabs.sendRequest. They are runtime messages kept
      // apart from onMessage's, so requests travel wrapped and only onRequest listeners unwrap them.
      // Content scripts use them too, so this isn't limited to extension pages.
      for (const { root } of roots) {
        let runtime;
        try { runtime = root.runtime; } catch (e) { continue; }
        if (!runtime || typeof runtime.sendMessage !== 'function' || !runtime.onMessage) continue;
        let extension;
        try { extension = root.extension; } catch (e) {}
        if (!extension || typeof extension !== 'object') {
          extension = {};
          add(root, 'extension', extension);
        }
        const isRequest = (message) => !!message && typeof message === 'object' && Object.prototype.hasOwnProperty.call(message, '__tuffRequest');
        // The callback gets the response, or nothing when there's no listener.
        const answered = (promise, callback) => {
          const settle = (value) => { if (typeof callback === 'function') { try { callback(value); } catch (e) {} } };
          promise.then(settle, () => settle(undefined));
        };
        const requestEvent = (source) => {
          const wrappers = new Map();
          return {
            addListener: (fn) => {
              if (typeof fn !== 'function' || wrappers.has(fn) || !source) return;
              // Old listeners could answer whenever they liked, so one that takes sendResponse keeps
              // the channel open.
              const wrapper = (message, sender, sendResponse) => {
                if (!isRequest(message)) return undefined;
                return fn(message.__tuffRequest, sender, sendResponse) === true || fn.length >= 3;
              };
              wrappers.set(fn, wrapper);
              source.addListener(wrapper);
            },
            removeListener: (fn) => {
              const wrapper = wrappers.get(fn);
              if (!wrapper) return;
              wrappers.delete(fn);
              source.removeListener(wrapper);
            },
            hasListener: (fn) => wrappers.has(fn),
            hasListeners: () => wrappers.size > 0,
          };
        };
        if (absent(extension, 'sendRequest')) {
          add(extension, 'sendRequest', (...args) => {
            const callback = args.length && typeof args[args.length - 1] === 'function' ? args.pop() : undefined;
            // sendRequest(extensionId, request) is meant for another extension's onRequestExternal (WebKit refuses such messages for now).
            const promise = args.length >= 2 && typeof args[0] === 'string'
              ? runtime.sendMessage(args[0], { __tuffRequest: args[1] })
              : runtime.sendMessage({ __tuffRequest: args[0] });
            answered(Promise.resolve(promise), callback);
          });
        }
        if (absent(extension, 'onRequest')) add(extension, 'onRequest', requestEvent(runtime.onMessage));
        let external;
        try { external = runtime.onMessageExternal; } catch (e) {}
        if (external && typeof external.addListener === 'function' && absent(extension, 'onRequestExternal')) {
          add(extension, 'onRequestExternal', requestEvent(external));
        }
        let tabs;
        try { tabs = root.tabs; } catch (e) {}
        if (tabs && typeof tabs.sendMessage === 'function' && !embedded) {
          if (absent(tabs, 'sendRequest')) {
            add(tabs, 'sendRequest', (tabId, request, callback) => answered(Promise.resolve(tabs.sendMessage(tabId, { __tuffRequest: request })), callback));
          }
          if (absent(tabs, 'getAllInWindow')) {
            add(tabs, 'getAllInWindow', (windowId, callback) => {
              if (typeof windowId === 'function') { callback = windowId; windowId = undefined; }
              const query = typeof windowId === 'number' && windowId >= 0 ? { windowId: windowId } : { currentWindow: true };
              const promise = Promise.resolve(tabs.query(query));
              if (typeof callback !== 'function') return promise;
              promise.then((list) => { try { callback(list); } catch (e) {} }, () => { try { callback([]); } catch (e) {} });
              return undefined;
            });
          }
          pins.push(tabs);
        }
        pins.push(extension, runtime);
      }

      // WebKit's webRequest reports every document load as `main_frame`, iframes included (an
      // iframe's details carry a non-zero frameId but still say main_frame). uBlock Origin
      // answers a blocked main_frame by sending the whole tab to its "page blocked" screen, so a
      // blocked ad iframe took over the page. Give listeners Chrome's `sub_frame` for those, and
      // apply `types` filters to the corrected type (WebKit would filter on its own).
      //
      // Two more gaps in the same details, filled from what the shim sees of each tab's frames:
      // - A frame directly inside the page names the page by WebKit's internal frame id as its
      //   parentFrameId, though the page itself is reported as frame 0 (here and in
      //   webNavigation). Extensions that build a tree of frames could not attach those frames.
      // - `initiator` (Chrome) is missing and `documentUrl` / `originUrl` (Firefox) are empty, so
      //   an extension could not tell which page made a request, or whether it was third-party.
      if (privileged) {
        const isEvent = (event) => event && typeof event === 'object' && typeof event.addListener === 'function';
        // tabId -> { page: WebKit's id for the page frame, urls: Map(frameId -> document URL) }
        const frames = new Map();
        const tabFrames = (tabId) => {
          let entry = frames.get(tabId);
          if (!entry) { entry = { page: undefined, urls: new Map() }; frames.set(tabId, entry); }
          return entry;
        };
        const isDocument = (details) => details.type === 'main_frame' || details.type === 'sub_frame';
        const parentOf = (entry, parent) => {
          if (typeof parent !== 'number' || parent <= 0) return parent;
          if (entry.page === parent) return 0;
          // A parent the shim has never seen load is the page frame (its own load is reported as 0).
          if (!entry.urls.has(parent) && entry.page === undefined) { entry.page = parent; return 0; }
          return parent;
        };
        const observe = (details) => {
          if (!details || typeof details.tabId !== 'number' || details.tabId < 0 || !isDocument(details)) return;
          if (details.frameId === 0) {
            frames.set(details.tabId, { page: undefined, urls: new Map([[0, details.url]]) });
          } else if (typeof details.frameId === 'number') {
            const entry = tabFrames(details.tabId);
            parentOf(entry, details.parentFrameId);
            entry.urls.set(details.frameId, details.url);
          }
        };
        const originOf = (url) => { try { return new URL(url).origin; } catch (e) { return undefined; } };
        const fixDetails = (details) => {
          if (!details || typeof details !== 'object') return details;
          const changes = {};
          if (details.type === 'main_frame' && typeof details.frameId === 'number' && details.frameId !== 0) changes.type = 'sub_frame';
          if (details.frameType === undefined && typeof details.frameId === 'number') {
            changes.frameType = details.frameId === 0 ? 'outermost_frame' : 'sub_frame';
          }
          const entry = typeof details.tabId === 'number' && details.tabId >= 0 ? frames.get(details.tabId) : undefined;
          if (entry) {
            const parent = parentOf(entry, details.parentFrameId);
            if (parent !== details.parentFrameId) changes.parentFrameId = parent;
            // The document that made the request: the parent for a frame load, else the frame itself.
            const from = isDocument(details) ? parent : details.frameId;
            const documentURL = typeof from === 'number' && from >= 0 ? entry.urls.get(from) : undefined;
            if (documentURL) {
              if (!details.documentUrl) changes.documentUrl = documentURL;
              if (!details.originUrl) changes.originUrl = documentURL;
              if (details.initiator === undefined) {
                const origin = originOf(documentURL);
                if (origin) changes.initiator = origin;
              }
            }
          }
          const names = Object.keys(changes);
          if (!names.length) return details;
          try { for (const name of names) details[name] = changes[name]; } catch (e) {}
          return names.every((name) => details[name] === changes[name]) ? details : Object.assign({}, details, changes);
        };
        // Keeps `frames` current for every frame load, whatever the extension itself listens to.
        // Added with the extension's first webRequest listener, so extensions that never use
        // webRequest don't get woken for every request.
        let tracking = false;
        const startTracking = (webRequest, root) => {
          if (tracking) return;
          tracking = true;
          const watch = (name, listener, types) => {
            const event = webRequest[name];
            if (!isEvent(event)) return;
            const original = event.addListener.__tuffOriginal || event.addListener;
            try { original(listener, { urls: ['<all_urls>'], types }); }
            catch (e) { try { original(listener, { urls: ['<all_urls>'] }); } catch (e2) {} }
          };
          watch('onBeforeRequest', (details) => { observe(details); }, ['main_frame', 'sub_frame']);
          watch('onBeforeRedirect', (details) => {
            if (!details || !isDocument(details) || typeof details.redirectUrl !== 'string') return;
            const id = details.frameId;
            if (typeof details.tabId === 'number' && typeof id === 'number' && frames.has(details.tabId)) {
              frames.get(details.tabId).urls.set(id, details.redirectUrl);
            }
          }, ['main_frame', 'sub_frame']);
          try { root.tabs.onRemoved.addListener((tabId) => { frames.delete(tabId); }); } catch (e) {}
        };
        for (const { root } of roots) {
          let webRequest;
          try { webRequest = root.webRequest; } catch (e) { continue; }
          if (!webRequest || typeof webRequest !== 'object') continue;
          for (const name of events.webRequest) {
            let event;
            try { event = webRequest[name]; } catch (e) { continue; }
            if (!isEvent(event) || event.addListener.__tuff) continue;
            const addListener = event.addListener;
            const removeListener = typeof event.removeListener === 'function' ? event.removeListener : null;
            const hasListener = typeof event.hasListener === 'function' ? event.hasListener : null;
            const wrappers = new Map();
            const tolerant = (listener, filter, ...rest) => {
              if (typeof listener !== 'function') return addListener(listener, filter, ...rest);
              startTracking(webRequest, root);
              let wanted = null;
              if (filter && typeof filter === 'object' && Array.isArray(filter.types)) {
                wanted = new Set(filter.types);
                if (wanted.has('main_frame') !== wanted.has('sub_frame')) {
                  filter = Object.assign({}, filter, { types: [...new Set([...filter.types, 'main_frame', 'sub_frame'])] });
                } else {
                  wanted = null;
                }
              }
              const wrapper = function (details, ...more) {
                if (name === 'onBeforeRequest') observe(details);
                details = fixDetails(details);
                if (wanted && details && !wanted.has(details.type)) return undefined;
                return listener.call(this, details, ...more);
              };
              const list = wrappers.get(listener) || [];
              list.push(wrapper);
              wrappers.set(listener, list);
              return addListener(wrapper, filter, ...rest);
            };
            tolerant.__tuff = true;
            tolerant.__tuffOriginal = addListener;
            add(event, 'addListener', tolerant);
            if (removeListener) {
              add(event, 'removeListener', (listener, ...rest) => {
                const list = wrappers.get(listener);
                if (!list) return removeListener(listener, ...rest);
                wrappers.delete(listener);
                for (const wrapper of list) { try { removeListener(wrapper, ...rest); } catch (e) {} }
                return undefined;
              });
            }
            if (hasListener) {
              add(event, 'hasListener', (listener, ...rest) => wrappers.has(listener) || hasListener(listener, ...rest));
            }
            pins.push(event);
          }
          pins.push(webRequest);
        }
      }

      // WebKit throws, synchronously, when permissions.contains / request / remove names a
      // permission it does not know (clipboardRead, say); Chrome and Firefox answer. Thrown at
      // the top of a module, that stops the whole page. A permission neither WebKit nor Tuff
      // implements can never be held: `contains` answers false, and `request` / `remove`
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
      if (privileged && !embedded) {
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

      // Native implementations for APIs WebKit lacks but Tuff can provide (topSites, history,
      // browsingData, management). They reach Tuff through the same tabs.create bridge as the side
      // panel, with a private tuff-api:// URL; the answer comes back in the call's error. The methods
      // are real; their events arrive through the native event relay below.
      if (privileged && !embedded) {
        const nativePermissionNames = new Set([
          'topSites', 'history', 'browsingData', 'management', 'sessions', 'notifications', 'offscreen',
          'identity', 'downloads', 'system.cpu', 'system.memory', 'system.storage', 'power', 'idle', 'tts', 'ttsEngine',
          'search', 'userScripts', 'tabGroups', 'contextualIdentities', 'contentSettings', 'find', 'omnibox',
          'theme', 'privacy', 'proxy', 'fontSettings', 'browserSettings', 'bookmarks', 'readingList', 'declarativeContent',
          'captivePortal', 'system.display', 'dns', 'pageCapture', 'debugger', 'webAuthenticationProxy', 'tabHide',
        ]);
        for (const { root, label } of roots) {
          let tabs;
          try { tabs = root.tabs; } catch (e) { continue; }
          if (!tabs || typeof tabs.create !== 'function') continue;
          const create = tabs.create;
          const marker = '__tuff_api__:';
          const call = async (namespace, method, args) => {
            const url = 'tuff-api://' + namespace + '/' + method + '/?d=' + encodeURIComponent(JSON.stringify(args || {}));
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
          const api = (impl) => function (...args) {
            const callback = args.length && typeof args[args.length - 1] === 'function' ? args.pop() : null;
            const promise = Promise.resolve().then(() => impl(...args));
            if (!callback) return promise;
            promise.then((value) => { try { callback(value); } catch (e) {} }, () => { try { callback(); } catch (e) {} });
            return undefined;
          };
          let permissionAPI;
          try { permissionAPI = root.permissions; } catch (e) {}
          if (permissionAPI && typeof permissionAPI === 'object') {
            for (const name of ['contains', 'request', 'remove']) {
              const original = permissionAPI[name];
              if (typeof original !== 'function') continue;
              add(permissionAPI, name, api(async (details) => {
                const requested = details && Array.isArray(details.permissions) ? details.permissions : [];
                const native = requested.filter((p) => nativePermissionNames.has(p));
                const standard = requested.filter((p) => !nativePermissionNames.has(p));
                const origins = details && Array.isArray(details.origins) ? details.origins : [];
                let answer = true;
                if (standard.length || origins.length || !native.length) {
                  answer = !!(await original(Object.assign({}, details, { permissions: standard, origins })));
                }
                if (answer && native.length) answer = !!(await call('__permissions', name, { permissions: native }));
                return answer;
              }));
            }
            pins.push(permissionAPI);
          }
          // Real events for the native APIs. Tuff pushes them through a relay page's
          // runtime.sendMessage (a wake event for the worker); dispatch to listeners here. Adding the
          // first listener subscribes with Tuff so it only wakes extensions that actually listen.
          // listener -> its filter (webNavigation's `{ url: [UrlFilter] }`), per event name.
          const nativeEvents = {};
          const eventObjects = {};
          const event = (name) => {
            if (eventObjects[name]) return eventObjects[name];
            const listeners = new Map();
            nativeEvents[name] = listeners;
            return eventObjects[name] = {
              addListener: (fn, filter) => {
                if (typeof fn !== 'function') return;
                const first = listeners.size === 0;
                listeners.set(fn, filter);
                if (first) call('__events', 'subscribe', { event: name }).catch(() => {});
              },
              removeListener: (fn) => {
                listeners.delete(fn);
                if (listeners.size === 0) call('__events', 'unsubscribe', { event: name }).catch(() => {});
              },
              hasListener: (fn) => listeners.has(fn),
              hasListeners: () => listeners.size > 0,
            };
          };
          // Chrome's events.UrlFilter, for listeners added with `{ url: [...] }`.
          const urlMatches = (url, f) => {
            let u; try { u = new URL(url); } catch (e) { return false; }
            const host = u.hostname, path = u.pathname, query = u.search.slice(u.search.startsWith('?') ? 1 : 0);
            const plain = u.href.replace(/#.*$/, '');
            const checks = [
              ['hostContains', (v) => ('.' + host).includes(v)], ['hostEquals', (v) => host === v],
              ['hostPrefix', (v) => host.startsWith(v)], ['hostSuffix', (v) => host.endsWith(v)],
              ['pathContains', (v) => path.includes(v)], ['pathEquals', (v) => path === v],
              ['pathPrefix', (v) => path.startsWith(v)], ['pathSuffix', (v) => path.endsWith(v)],
              ['queryContains', (v) => query.includes(v)], ['queryEquals', (v) => query === v],
              ['queryPrefix', (v) => query.startsWith(v)], ['querySuffix', (v) => query.endsWith(v)],
              ['urlContains', (v) => plain.includes(v)], ['urlEquals', (v) => plain === v],
              ['urlPrefix', (v) => plain.startsWith(v)], ['urlSuffix', (v) => plain.endsWith(v)],
              ['urlMatches', (v) => { try { return new RegExp(v).test(plain); } catch (e) { return false; } }],
              ['originAndPathMatches', (v) => { try { return new RegExp(v).test(u.origin + path); } catch (e) { return false; } }],
              ['schemes', (v) => Array.isArray(v) && v.includes(u.protocol.replace(/:$/, ''))],
              ['ports', (v) => Array.isArray(v) && v.some((p) => {
                const port = Number(u.port || (u.protocol === 'https:' ? 443 : u.protocol === 'http:' ? 80 : 0));
                return Array.isArray(p) ? port >= p[0] && port <= p[1] : port === p;
              })],
            ];
            return checks.every(([key, test]) => f[key] === undefined || test(f[key]));
          };
          const passes = (filter, args) => {
            if (!filter || !Array.isArray(filter.url) || !filter.url.length) return true;
            const details = args[0];
            if (!details || typeof details.url !== 'string') return true;
            return filter.url.some((f) => f && typeof f === 'object' && urlMatches(details.url, f));
          };
          // Tuff names tabs by their index (it can't know WebKit's tab ids); swap in the ids.
          const resolve = async (msg) => {
            const args = Array.isArray(msg.args) ? msg.args : [];
            if (msg.tabs && args[0] && typeof args[0] === 'object') {
              let all = [];
              try { all = await root.tabs.query({}); } catch (e) {}
              for (const field of Object.keys(msg.tabs)) {
                const tab = all.find((t) => t.index === msg.tabs[field]);
                args[0][field] = tab ? tab.id : -1;
              }
            }
            if (msg.window) {
              try { args[0] = await root.windows.getLastFocused(); } catch (e) {}
            }
            // A tab group or theme: its window's id.
            if ((msg.groupWindow || msg.themeWindow) && args[0] && typeof args[0] === 'object') {
              try { args[0].windowId = (await root.windows.getLastFocused()).id; } catch (e) {}
            }
            // omnibox.onInputChanged: the listener's suggest() callback.
            if (msg.suggest !== undefined) {
              const request = msg.suggest;
              args.push((results) => { call('omnibox', 'suggest', { request, suggestions: results || [] }).catch(() => {}); });
            }
            // ttsEngine.onSpeak: the listener's sendTtsEvent(event) callback.
            if (msg.ttsRequestId !== undefined) {
              const requestId = msg.ttsRequestId;
              args.push((ev) => { call('ttsEngine', 'sendTtsEvent', { requestId, event: ev || {} }).catch(() => {}); });
            }
            // User script messaging: resolve sender.tab from tab index.
            if (typeof msg.senderTabIndex === 'number') {
              const sender = msg.__tuffEvent === 'runtime.__userScriptConnect' ? args[2] : args[1];
              if (sender && typeof sender === 'object') {
                try {
                  const all = await root.tabs.query({});
                  const tab = all.find((t) => t.index === msg.senderTabIndex);
                  if (tab) sender.tab = tab;
                } catch (e) {}
              }
            }
            if (msg.userScriptReply !== undefined) {
              args.push(msg.userScriptReply);
            }
            if (msg.filenameRequest !== undefined) {
              args.push(msg.filenameRequest);
            }
            if (msg.proxyRequestId !== undefined) {
              args.push(msg.proxyRequestId);
            }
            if (typeof msg.menuTabIndex === 'number') {
              let tab;
              try {
                const all = await root.tabs.query({});
                tab = all.find((t) => t.index === msg.menuTabIndex);
              } catch (e) {}
              args.push(tab);
            }
            return args;
          };
          const seenDeliveries = new Set();
          const deliveryOrder = [];
          try {
            root.runtime.onMessage.addListener((msg) => {
              if (msg && typeof msg === 'object' && msg.__tuffEvent && nativeEvents[msg.__tuffEvent]) {
                const delivery = msg.__tuffDelivery;
                if (typeof delivery === 'string') {
                  if (seenDeliveries.has(delivery)) return;
                  seenDeliveries.add(delivery);
                  deliveryOrder.push(delivery);
                  if (deliveryOrder.length > 1000) seenDeliveries.delete(deliveryOrder.shift());
                }
                const listeners = nativeEvents[msg.__tuffEvent];
                if (!listeners.size) return;
                resolve(msg).then((args) => {
                  for (const [fn, filter] of [...listeners]) {
                    if (!passes(filter, args)) continue;
                    try { fn(...args); } catch (e) {}
                  }
                });
              }
            });
          } catch (e) {}
          // Events inside namespaces WebKit has, which Tuff drives itself.
          const nativeEventsIn = (namespace, names) => {
            let object;
            try { object = root[namespace]; } catch (e) { return; }
            if (!object || typeof object !== 'object') return;
            for (const name of names) {
              if (absent(object, name)) add(object, name, event(namespace + '.' + name));
            }
            pins.push(object);
          };
          nativeEventsIn('webNavigation', ['onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onCreatedNavigationTarget']);
          nativeEventsIn('tabs', ['onZoomChange']);
          nativeEventsIn('windows', ['onBoundsChanged']);
          const implement = (name, methods) => {
            if (absent(root, name)) { add(root, name, methods); pins.push(methods); }
          };

          implement('topSites', {
            get: api((options) => call('topSites', 'get', options)),
          });
          implement('history', {
            search: api((query) => call('history', 'search', query)),
            getVisits: api((details) => call('history', 'getVisits', details)),
            addUrl: api((details) => call('history', 'addUrl', details)),
            deleteUrl: api((details) => call('history', 'deleteUrl', details)),
            deleteRange: api((range) => call('history', 'deleteRange', range)),
            deleteAll: api(() => call('history', 'deleteAll', {})),
            onVisited: event('history.onVisited'),
            onVisitRemoved: event('history.onVisitRemoved'),
            onTitleChanged: event('history.onTitleChanged'),
          });
          const browsingData = {
            remove: api((options, dataToRemove) => call('browsingData', 'remove', Object.assign({}, options, { dataToRemove: dataToRemove }))),
            removeCache: api((options) => call('browsingData', 'removeCache', options)),
            removeCookies: api((options) => call('browsingData', 'removeCookies', options)),
            removeLocalStorage: api((options) => call('browsingData', 'removeLocalStorage', options)),
            removeHistory: api((options) => call('browsingData', 'removeHistory', options)),
            settings: api(() => call('browsingData', 'settings', {})),
          };
          // The one-type shortcuts are remove() with that type.
          for (const [method, type] of [['removeAppcache', 'appcache'], ['removeCacheStorage', 'cacheStorage'],
            ['removeDownloads', 'downloads'], ['removeFileSystems', 'fileSystems'], ['removeFormData', 'formData'],
            ['removeIndexedDB', 'indexedDB'], ['removePasswords', 'passwords'], ['removePluginData', 'pluginData'],
            ['removeServiceWorkers', 'serviceWorkers'], ['removeWebSQL', 'webSQL']]) {
            browsingData[method] = api((options) => call('browsingData', 'remove', Object.assign({}, options, { dataToRemove: { [type]: true } })));
          }
          implement('browsingData', browsingData);
          implement('management', {
            getAll: api(() => call('management', 'getAll', {})),
            get: api((id) => call('management', 'get', { id: id })),
            getSelf: api(() => call('management', 'getSelf', {})),
            getPermissionWarningsById: api((id) => call('management', 'getPermissionWarningsById', { id: id })),
            getPermissionWarningsByManifest: api((manifest) => call('management', 'getPermissionWarningsByManifest', { manifest: manifest })),
            setEnabled: api((id, enabled) => call('management', 'setEnabled', { id: id, enabled: enabled })),
            uninstall: api((id) => call('management', 'uninstall', { id: id })),
            uninstallSelf: api((options) => call('management', 'uninstallSelf', options || {})),
            install: api((options) => call('management', 'install', options || {})),
            onInstalled: event('management.onInstalled'),
            onUninstalled: event('management.onUninstalled'),
            onEnabled: event('management.onEnabled'),
            onDisabled: event('management.onDisabled'),
          });
          implement('sessions', {
            getRecentlyClosed: api((filter) => call('sessions', 'getRecentlyClosed', filter)),
            restore: api((sessionId) => call('sessions', 'restore', { sessionId: sessionId })),
            getDevices: api((filter) => call('sessions', 'getDevices', filter)),
            forgetClosedTab: api((windowId, sessionId) => call('sessions', 'forgetClosedTab', { sessionId: sessionId })),
            forgetClosedWindow: api((sessionId) => call('sessions', 'forgetClosedWindow', { sessionId: sessionId })),
            // Firefox's values kept with a tab or the window (ExtensionSessionValues); stored as JSON.
            getTabValue: api(async (tabId, key) => call('sessions', 'getValue', { tabIndex: await indexOf(tabId), key: key })),
            setTabValue: api(async (tabId, key, value) =>
              call('sessions', 'setValue', { tabIndex: await indexOf(tabId), key: key, value: JSON.parse(JSON.stringify(value === undefined ? null : value)) })),
            removeTabValue: api(async (tabId, key) => call('sessions', 'removeValue', { tabIndex: await indexOf(tabId), key: key })),
            getWindowValue: api((windowId, key) => call('sessions', 'getValue', { key: key })),
            setWindowValue: api((windowId, key, value) =>
              call('sessions', 'setValue', { key: key, value: JSON.parse(JSON.stringify(value === undefined ? null : value)) })),
            removeWindowValue: api((windowId, key) => call('sessions', 'removeValue', { key: key })),
            onChanged: event('sessions.onChanged'),
            MAX_SESSION_RESULTS: 25,
          });
          implement('notifications', {
            create: api((notificationId, options) => {
              if (notificationId && typeof notificationId === 'object') { options = notificationId; notificationId = undefined; }
              return call('notifications', 'create', { notificationId: notificationId, options: options });
            }),
            clear: api((notificationId) => call('notifications', 'clear', { notificationId: notificationId })),
            update: api((notificationId, options) => call('notifications', 'update', { notificationId: notificationId, options: options })),
            getAll: api(() => call('notifications', 'getAll', {})),
            getPermissionLevel: api(() => call('notifications', 'getPermissionLevel', {})),
            onClicked: event('notifications.onClicked'),
            onClosed: event('notifications.onClosed'),
            onButtonClicked: event('notifications.onButtonClicked'),
            onPermissionLevelChanged: event('notifications.onPermissionLevelChanged'),
            onShowSettings: stub(label + '.notifications.onShowSettings', true),
          });
          implement('offscreen', {
            createDocument: api((parameters) => call('offscreen', 'createDocument', parameters)),
            closeDocument: api(() => call('offscreen', 'closeDocument', {})),
            hasDocument: api(() => call('offscreen', 'hasDocument', {})),
            Reason: {
              AUDIO_PLAYBACK: 'AUDIO_PLAYBACK', BLOBS: 'BLOBS', CLIPBOARD: 'CLIPBOARD',
              DISPLAY_MEDIA: 'DISPLAY_MEDIA', DOM_PARSER: 'DOM_PARSER', DOM_SCRAPING: 'DOM_SCRAPING',
              IFRAME_SCRIPTING: 'IFRAME_SCRIPTING', TESTING: 'TESTING', USER_MEDIA: 'USER_MEDIA',
              WEB_RTC: 'WEB_RTC', WORKERS: 'WORKERS', BROADCAST_CHANNEL: 'BROADCAST_CHANNEL',
              LOCAL_STORAGE: 'LOCAL_STORAGE', MATCH_MEDIA: 'MATCH_MEDIA', GEOLOCATION: 'GEOLOCATION',
            },
          });
          implement('identity', {
            getRedirectURL: (path) => {
              let id = '';
              try { id = root.runtime.id || ''; } catch (e) {}
              let p = path || '';
              while (p.charAt(0) === '/') p = p.slice(1);
              return 'https://' + id + '.chromiumapp.org/' + p;
            },
            launchWebAuthFlow: api((details) => call('identity', 'launchWebAuthFlow', details)),
            onSignInChanged: event('identity.onSignInChanged'),
          });
          const determiningListeners = new Set();
          const determiningSource = event('downloads.onDeterminingFilename');
          const onDeterminingRaw = (item, requestId) => {
            if (!determiningListeners.size) {
              call('downloads', 'suggestFilename', { requestId }).catch(() => {});
              return;
            }
            let suggestion = null;
            let pendingAsync = 0;
            let sent = false;
            const flush = () => {
              if (sent || pendingAsync > 0) return;
              sent = true;
              const payload = { requestId };
              if (suggestion && typeof suggestion === 'object') {
                if (typeof suggestion.filename === 'string') payload.filename = suggestion.filename;
                if (typeof suggestion.conflictAction === 'string') payload.conflictAction = suggestion.conflictAction;
              }
              call('downloads', 'suggestFilename', payload).catch(() => {});
            };
            for (const fn of [...determiningListeners]) {
              let called = false;
              let isAsync = false;
              const suggest = (s) => {
                if (called) return;
                called = true;
                if (s && typeof s === 'object') suggestion = s;
                if (isAsync) { pendingAsync = Math.max(0, pendingAsync - 1); flush(); }
              };
              try {
                if (fn(item, suggest) === true && !called) {
                  isAsync = true;
                  pendingAsync += 1;
                }
              } catch (e) {}
            }
            flush();
          };
          const onDeterminingFilename = {
            addListener: (fn) => {
              if (typeof fn !== 'function') return;
              const first = determiningListeners.size === 0;
              determiningListeners.add(fn);
              if (first) determiningSource.addListener(onDeterminingRaw);
            },
            removeListener: (fn) => {
              determiningListeners.delete(fn);
              if (determiningListeners.size === 0) determiningSource.removeListener(onDeterminingRaw);
            },
            hasListener: (fn) => determiningListeners.has(fn),
            hasListeners: () => determiningListeners.size > 0,
          };
          implement('downloads', {
            download: api((options) => call('downloads', 'download', options)),
            search: api((query) => call('downloads', 'search', query)),
            erase: api((query) => call('downloads', 'erase', query)),
            cancel: api((id) => call('downloads', 'cancel', { id: id })),
            open: api((id) => call('downloads', 'open', { id: id })),
            show: api((id) => call('downloads', 'show', { id: id })),
            pause: api((id) => call('downloads', 'pause', { id: id })),
            resume: api((id) => call('downloads', 'resume', { id: id })),
            removeFile: api((id) => call('downloads', 'removeFile', { id: id })),
            getFileIcon: api((id, options) => call('downloads', 'getFileIcon', { id: id, size: options && options.size })),
            showDefaultFolder: api(() => call('downloads', 'showDefaultFolder', {})),
            // Tuff doesn't hold back dangerous files, and has no download shelf to hide.
            acceptDanger: api(() => undefined),
            setShelfEnabled: api(() => undefined),
            setUiOptions: api(() => undefined),
            drag: (id) => { call('downloads', 'drag', { id: id }).catch(() => {}); return undefined; },
            onCreated: event('downloads.onCreated'),
            onChanged: event('downloads.onChanged'),
            onErased: event('downloads.onErased'),
            onDeterminingFilename: onDeterminingFilename,
          });
          implement('system', {
            display: {
              getInfo: api(() => call('system.display', 'getInfo', {})),
              getDisplayLayout: api(() => call('system.display', 'getDisplayLayout', {})),
              onDisplayChanged: event('system.display.onDisplayChanged'),
            },
            cpu: { getInfo: api(() => call('system.cpu', 'getInfo', {})) },
            memory: { getInfo: api(() => call('system.memory', 'getInfo', {})) },
            storage: {
              getInfo: api(() => call('system.storage', 'getInfo', {})),
              getAvailableCapacity: api((id) => call('system.storage', 'getAvailableCapacity', { id: String(id) })),
              ejectDevice: api((id) => call('system.storage', 'ejectDevice', { id: String(id) })),
              onAttached: event('system.storage.onAttached'),
              onDetached: event('system.storage.onDetached'),
            },
          });
          // Firefox browser.dns.
          implement('dns', {
            resolve: api((hostname, flags) => call('dns', 'resolve', {
              hostname: String(hostname || ''), flags: Array.isArray(flags) ? flags : (flags ? [String(flags)] : []),
            })),
          });
          implement('power', {
            requestKeepAwake: api((level) => call('power', 'requestKeepAwake', { level: level })),
            releaseKeepAwake: api(() => call('power', 'releaseKeepAwake', {})),
          });
          implement('idle', {
            queryState: api((interval) => call('idle', 'queryState', { detectionIntervalInSeconds: interval })),
            setDetectionInterval: api((interval) => call('idle', 'setDetectionInterval', { intervalInSeconds: interval })),
            onStateChanged: event('idle.onStateChanged'),
          });
          const ttsOnEvent = event('tts.onEvent');
          const ttsCallbacks = new Map();
          let ttsListening = false;
          const ensureTtsForwarder = () => {
            if (ttsListening) return;
            ttsListening = true;
            ttsOnEvent.addListener((ev) => {
              if (!ev || !ev.utteranceId) return;
              const fn = ttsCallbacks.get(String(ev.utteranceId));
              if (!fn) return;
              if (ev.type === 'end' || ev.type === 'interrupted' || ev.type === 'cancelled' || ev.type === 'error') {
                ttsCallbacks.delete(String(ev.utteranceId));
              }
              try { fn(ev); } catch (e) {}
            });
          };
          implement('tts', {
            speak: api(async (utterance, options) => {
              const opts = Object.assign({}, options, { utterance: utterance });
              const onEvent = opts.onEvent;
              delete opts.onEvent;
              if (typeof onEvent === 'function') ensureTtsForwarder();
              const id = await call('tts', 'speak', opts);
              if (typeof onEvent === 'function' && id !== undefined) ttsCallbacks.set(String(id), onEvent);
              return undefined;
            }),
            stop: api(() => call('tts', 'stop', {})),
            pause: api(() => call('tts', 'pause', {})),
            resume: api(() => call('tts', 'resume', {})),
            isSpeaking: api(() => call('tts', 'isSpeaking', {})),
            getVoices: api(() => call('tts', 'getVoices', {})),
            onEvent: ttsOnEvent,
            onVoicesChanged: event('tts.onVoicesChanged'),
          });
          implement('ttsEngine', {
            updateVoices: api((voices) => call('ttsEngine', 'updateVoices', { voices: Array.isArray(voices) ? voices : [] })),
            sendTtsEvent: api((requestId, ev) => call('ttsEngine', 'sendTtsEvent', { requestId: requestId, event: ev || {} })),
            onSpeak: event('ttsEngine.onSpeak'),
            onStop: event('ttsEngine.onStop'),
            onPause: event('ttsEngine.onPause'),
            onResume: event('ttsEngine.onResume'),
          });
          // Firefox browser.captivePortal.
          implement('captivePortal', {
            getState: api(() => call('captivePortal', 'getState', {})),
            getLastChecked: api(() => call('captivePortal', 'getLastChecked', {})),
            onStateChanged: event('captivePortal.onStateChanged'),
            onConnectivityAvailable: event('captivePortal.onConnectivityAvailable'),
            canonicalURL: {
              get: api(() => ({ value: 'http://captive.apple.com/hotspot-detect.html', levelOfControl: 'not_controllable' })),
              set: api(() => { throw new Error('captivePortal.canonicalURL is read-only.'); }),
              clear: api(() => { throw new Error('captivePortal.canonicalURL is read-only.'); }),
              onChange: stub(label + '.captivePortal.canonicalURL.onChange', true),
            },
          });
          implement('search', {
            query: api((query) => call('search', 'query', query)),
            get: api(() => call('search', 'get', {})),
            // Firefox: { query, engine, disposition, tabId }. Tuff searches with its own engine.
            search: api(async (properties) => {
              const p = properties || {};
              const args = { text: p.query, disposition: p.disposition || (p.tabId === undefined ? undefined : 'CURRENT_TAB') };
              if (p.tabId !== undefined && p.tabId !== null) args.tabIndex = (await root.tabs.get(p.tabId)).index;
              return call('search', 'query', args);
            }),
          });
          // Tab ids <-> Tuff's indexes in the window (Tuff can't know WebKit's ids).
          const indexOf = async (tabId) => (await root.tabs.get(tabId)).index;
          const indexesOf = async (ids) => Promise.all((Array.isArray(ids) ? ids : [ids]).map(indexOf));
          const focusedWindowId = async () => { try { return (await root.windows.getLastFocused()).id; } catch (e) { return -1; } };
          const inWindow = async (group) => { if (group && typeof group === 'object') group.windowId = await focusedWindowId(); return group; };
          let declared = [];
          try {
            const manifest = root.runtime.getManifest() || {};
            declared = [].concat(manifest.permissions || [], manifest.optional_permissions || []);
          } catch (e) {}
          // Tuff's events reach every page of the extension, so what Tuff asks the extension itself
          // to do is done by its background alone (the service worker, or a Manifest V2 page).
          let isBackground = typeof ServiceWorkerGlobalScope !== 'undefined' && scope instanceof ServiceWorkerGlobalScope;
          try { isBackground = isBackground || root.extension.getBackgroundPage() === scope; } catch (e) {}
          // An event made of several others, each listener's argument reshaped.
          const mappedEvent = (sources, transform) => {
            const wrappers = new Map();
            return {
              addListener: (fn) => {
                if (typeof fn !== 'function' || wrappers.has(fn)) return;
                wrappers.set(fn, sources.map(([source, extra]) => {
                  const wrapper = (details) => fn(transform(details, extra));
                  source.addListener(wrapper);
                  return [source, wrapper];
                }));
              },
              removeListener: (fn) => {
                (wrappers.get(fn) || []).forEach(([source, wrapper]) => source.removeListener(wrapper));
                wrappers.delete(fn);
              },
              hasListener: (fn) => wrappers.has(fn),
              hasListeners: () => wrappers.size > 0,
            };
          };

          // chrome.tabGroups, on Tuff's folders (see ExtensionGroups).
          implement('tabGroups', {
            get: api(async (groupId) => inWindow(await call('tabGroups', 'get', { groupId: groupId }))),
            query: api(async (queryInfo) => {
              const q = Object.assign({}, queryInfo);
              const wanted = q.windowId;
              delete q.windowId;
              const groups = (await call('tabGroups', 'query', q)) || [];
              const id = await focusedWindowId();
              groups.forEach((g) => { g.windowId = id; });
              return wanted === undefined || wanted === -2 || wanted === id ? groups : [];
            }),
            update: api(async (groupId, updateProperties) => inWindow(await call('tabGroups', 'update', { groupId: groupId, updateProperties: updateProperties || {} }))),
            move: api(async (groupId, moveProperties) => inWindow(await call('tabGroups', 'move', { groupId: groupId, moveProperties: moveProperties || {} }))),
            onCreated: event('tabGroups.onCreated'),
            onUpdated: event('tabGroups.onUpdated'),
            onMoved: event('tabGroups.onMoved'),
            onRemoved: event('tabGroups.onRemoved'),
            TAB_GROUP_ID_NONE: -1,
            Color: { GREY: 'grey', BLUE: 'blue', RED: 'red', YELLOW: 'yellow', GREEN: 'green', PINK: 'pink', PURPLE: 'purple', CYAN: 'cyan', ORANGE: 'orange' },
          });
          // tabs.group / ungroup, and the fields WebKit's tab objects lack (groupId, and Firefox's
          // cookieStoreId) for extensions that ask for tab groups or containers.
          let tabsNamespace;
          try { tabsNamespace = root.tabs; } catch (e) {}
          if (tabsNamespace && typeof tabsNamespace === 'object') {
            const t = tabsNamespace;
            if (absent(t, 'group')) {
              add(t, 'group', api(async (options) => {
                const o = options || {};
                return call('tabs', 'group', { tabs: await indexesOf(o.tabIds), groupId: o.groupId });
              }));
            }
            if (absent(t, 'ungroup')) {
              add(t, 'ungroup', api(async (tabIds) => call('tabs', 'ungroup', { tabs: await indexesOf(tabIds) })));
            }
            if (absent(t, 'TAB_ID_NONE')) add(t, 'TAB_ID_NONE', -1);
            if (absent(t, 'hide')) {
              add(t, 'hide', api(async (tabIds) => {
                const list = Array.isArray(tabIds) ? tabIds : [tabIds];
                const all = (await t.query({})) || [];
                const idByIndex = new Map(all.map((tab) => [tab.index, tab.id]));
                const indexes = list.map((id) => {
                  const found = all.find((tab) => tab.id === id);
                  return found ? found.index : -1;
                }).filter((i) => i >= 0);
                const hidden = (await call('tabs', 'hide', { tabs: indexes })) || [];
                return hidden.map((idx) => idByIndex.get(idx)).filter((id) => typeof id === 'number');
              }));
            }
            if (absent(t, 'show')) {
              add(t, 'show', api(async (tabIds) => {
                const indexes = await indexesOf(tabIds);
                return call('tabs', 'show', { tabs: indexes });
              }));
            }
            if (absent(t, 'moveInSuccession')) {
              add(t, 'moveInSuccession', api(async (tabIds, tabId, options) => {
                const indexes = await indexesOf(tabIds || []);
                let targetIndex = null;
                if (typeof tabId === 'number' && tabId >= 0) targetIndex = await indexOf(tabId);
                const opts = options && typeof options === 'object' ? options : {};
                return call('tabs', 'moveInSuccession', {
                  tabs: indexes, targetIndex: targetIndex, append: !!opts.append, insert: !!opts.insert,
                });
              }));
            }
            const wantsGroups = declared.includes('tabGroups');
            const wantsContainers = declared.includes('contextualIdentities');
            const wantsHide = declared.includes('tabHide');
            const query = t.query, get = t.get, createTab = t.create;
            if ((wantsGroups || wantsContainers || wantsHide) && typeof query === 'function' && typeof get === 'function') {
              const decorate = async (list) => {
                let extras = {};
                try { extras = (await call('tabs', 'extras', {})) || {}; } catch (e) {}
                for (const tab of list) {
                  if (!tab || typeof tab.index !== 'number') continue;
                  if (wantsGroups) { const g = (extras.groupIds || [])[tab.index]; tab.groupId = typeof g === 'number' ? g : -1; }
                  if (wantsContainers) tab.cookieStoreId = (extras.cookieStoreIds || [])[tab.index] || 'firefox-default';
                  if (wantsHide) tab.hidden = !!(extras.hidden || [])[tab.index];
                }
                return list;
              };
              add(t, 'query', api(async (queryInfo) => {
                const q = Object.assign({}, queryInfo);
                const groupId = q.groupId, cookieStoreId = q.cookieStoreId, hidden = q.hidden;
                delete q.groupId;
                delete q.cookieStoreId;
                delete q.hidden;
                let list = await decorate((await query.call(t, q)) || []);
                if (groupId !== undefined) list = list.filter((tab) => tab.groupId === groupId);
                if (cookieStoreId !== undefined) list = list.filter((tab) => tab.cookieStoreId === cookieStoreId);
                if (typeof hidden === 'boolean') list = list.filter((tab) => !!tab.hidden === hidden);
                return list;
              }));
              add(t, 'get', api(async (tabId) => (await decorate([await get.call(t, tabId)]))[0]));
              if (wantsContainers && typeof createTab === 'function') {
                add(t, 'create', api(async (properties) => {
                  const p = Object.assign({}, properties);
                  const store = p.cookieStoreId;
                  delete p.cookieStoreId;
                  if (!store || store === 'firefox-default') return createTab.call(t, p);
                  let url = p.url;
                  if (url) { try { url = new URL(url, scope.location.href).href; } catch (e) {} }
                  const index = await call('contextualIdentities', 'openTab', { url: url, active: p.active !== false, cookieStoreId: store });
                  const all = (await query.call(t, {})) || [];
                  return (await decorate(all.filter((tab) => tab.index === index)))[0];
                }));
              }
              pins.push(t);
            }
          }

          // Firefox containers, on Tuff's profiles.
          implement('contextualIdentities', {
            query: api((details) => call('contextualIdentities', 'query', details || {})),
            get: api((cookieStoreId) => call('contextualIdentities', 'get', { cookieStoreId: cookieStoreId })),
            create: api((details) => call('contextualIdentities', 'create', details || {})),
            update: api((cookieStoreId, details) => call('contextualIdentities', 'update', { cookieStoreId: cookieStoreId, details: details || {} })),
            remove: api((cookieStoreId) => call('contextualIdentities', 'remove', { cookieStoreId: cookieStoreId })),
            move: api((cookieStoreIds, position) => call('contextualIdentities', 'move', { cookieStoreIds: cookieStoreIds, position: position })),
            onCreated: event('contextualIdentities.onCreated'),
            onUpdated: event('contextualIdentities.onUpdated'),
            onRemoved: event('contextualIdentities.onRemoved'),
          });

          // types.ChromeSetting: chrome.privacy, chrome.proxy.settings, Firefox browserSettings.
          const setting = (path) => ({
            get: api((details) => call('settings', 'get', Object.assign({}, details, { path: path }))),
            set: api((details) => call('settings', 'set', { path: path, value: (details || {}).value, scope: (details || {}).scope })),
            clear: api((details) => call('settings', 'clear', { path: path, scope: (details || {}).scope })),
            onChange: event('settings.onChange.' + path),
          });
          const settingsIn = (prefix, names) => {
            const object = {};
            for (const name of names) object[name] = setting(prefix + '.' + name);
            return object;
          };
          implement('privacy', {
            network: settingsIn('privacy.network', ['networkPredictionEnabled', 'webRTCIPHandlingPolicy', 'peerConnectionEnabled',
              'httpsOnlyMode', 'globalPrivacyControl']),
            services: settingsIn('privacy.services', ['alternateErrorPagesEnabled', 'autofillEnabled', 'autofillAddressEnabled',
              'autofillCreditCardEnabled', 'passwordSavingEnabled', 'safeBrowsingEnabled', 'safeBrowsingExtendedReportingEnabled',
              'searchSuggestEnabled', 'spellingServiceEnabled', 'translationServiceEnabled']),
            websites: settingsIn('privacy.websites', ['thirdPartyCookiesAllowed', 'hyperlinkAuditingEnabled', 'referrersEnabled',
              'doNotTrackEnabled', 'protectedContentEnabled', 'topicsEnabled', 'fledgeEnabled', 'adMeasurementEnabled',
              'relatedWebsiteSetsEnabled', 'cookieConfig', 'trackingProtectionMode', 'firstPartyIsolate', 'resistFingerprinting']),
            IPHandlingPolicy: {
              DEFAULT: 'default', DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: 'default_public_and_private_interfaces',
              DEFAULT_PUBLIC_INTERFACE_ONLY: 'default_public_interface_only', DISABLE_NON_PROXIED_UDP: 'disable_non_proxied_udp',
            },
          });
          const proxyOnRequestListeners = new Map();
          const proxyOnRequestSource = event('proxy.onRequest');
          const handleProxyOnRequest = (details, requestId) => {
            if (!proxyOnRequestListeners.size) {
              call('proxy', 'replyOnRequest', { requestId, result: null }).catch(() => {});
              return;
            }
            let settled = false;
            const reply = (result, error) => {
              if (settled) return;
              settled = true;
              const payload = { requestId };
              if (error) payload.error = String(error);
              else payload.result = result === undefined ? null : result;
              call('proxy', 'replyOnRequest', payload).catch(() => {});
            };
            for (const [fn] of [...proxyOnRequestListeners]) {
              try {
                const out = fn(details);
                if (out && typeof out.then === 'function') {
                  out.then((v) => reply(v), (err) => reply(null, (err && err.message) || err));
                  return;
                }
                if (out !== undefined) {
                  reply(out);
                  return;
                }
              } catch (err) {
                reply(null, (err && err.message) || err);
                return;
              }
            }
            reply(null);
          };
          const syncProxyOnRequest = () => {
            if (!proxyOnRequestListeners.size) {
              proxyOnRequestSource.removeListener(handleProxyOnRequest);
              call('proxy', 'unregisterOnRequest', {}).catch(() => {});
              return;
            }
            const urls = [];
            for (const filter of proxyOnRequestListeners.values()) {
              if (filter && Array.isArray(filter.urls)) urls.push(...filter.urls);
            }
            proxyOnRequestSource.addListener(handleProxyOnRequest);
            call('proxy', 'registerOnRequest', { urls }).catch(() => {});
          };
          const proxyOnRequest = {
            addListener: (fn, filter) => {
              if (typeof fn !== 'function') return;
              proxyOnRequestListeners.set(fn, filter && typeof filter === 'object' ? filter : {});
              syncProxyOnRequest();
            },
            removeListener: (fn) => {
              if (!proxyOnRequestListeners.delete(fn)) return;
              syncProxyOnRequest();
            },
            hasListener: (fn) => proxyOnRequestListeners.has(fn),
            hasListeners: () => proxyOnRequestListeners.size > 0,
          };
          implement('proxy', {
            settings: setting('proxy.settings'),
            onRequest: proxyOnRequest,
            onProxyError: event('proxy.onProxyError'),
            onError: event('proxy.onError'),
            Mode: { DIRECT: 'direct', AUTO_DETECT: 'auto_detect', PAC_SCRIPT: 'pac_script', FIXED_SERVERS: 'fixed_servers', SYSTEM: 'system' },
            Scheme: { HTTP: 'http', HTTPS: 'https', QUIC: 'quic', SOCKS4: 'socks4', SOCKS5: 'socks5' },
          });
          // Firefox browser.pkcs11.
          implement('pkcs11', {
            installModule: api((name, flags) => call('pkcs11', 'installModule', { name: String(name || ''), flags: typeof flags === 'number' ? flags : 0 })),
            uninstallModule: api((name) => call('pkcs11', 'uninstallModule', { name: String(name || '') })),
            isModuleInstalled: api((name) => call('pkcs11', 'isModuleInstalled', { name: String(name || '') })),
            getModuleSlots: api((name) => call('pkcs11', 'getModuleSlots', { name: String(name || '') })),
          });
          implement('browserSettings', settingsIn('browserSettings', ['allowPopupsForUserEvents', 'cacheEnabled',
            'closeTabsByDoubleClick', 'contextMenuShowEvent', 'ftpProtocolEnabled', 'homepageOverride', 'imageAnimationBehavior',
            'newTabPageOverride', 'newTabPosition', 'openBookmarksInNewTabs', 'openSearchResultsInNewTabs',
            'openUrlbarResultsInNewTabs', 'webNotificationsDisabled', 'overrideDocumentColors', 'overrideContentColorScheme',
            'useDocumentFonts', 'zoomFullPage', 'zoomSiteSpecific', 'tlsMinimumVersion', 'tlsMaximumVersion', 'verticalTabs']));

          // chrome.fontSettings, on the same settings.
          const families = ['standard', 'sansserif', 'serif', 'fixed', 'cursive', 'fantasy', 'math'];
          const familyOf = (details) => (details && details.genericFamily) || 'standard';
          const sizeAPI = (key) => ({
            get: api(async () => {
              const r = await call('settings', 'get', { path: 'fontSettings.' + key });
              return { pixelSize: r.value, levelOfControl: r.levelOfControl };
            }),
            set: api((details) => call('settings', 'set', { path: 'fontSettings.' + key, value: (details || {}).pixelSize })),
            clear: api(() => call('settings', 'clear', { path: 'fontSettings.' + key })),
            onChanged: mappedEvent([[event('settings.onChange.fontSettings.' + key)]], (d) => ({ pixelSize: d.value, levelOfControl: d.levelOfControl })),
          });
          const defaultSize = sizeAPI('defaultFontSize'), fixedSize = sizeAPI('defaultFixedFontSize'), minimumSize = sizeAPI('minimumFontSize');
          implement('fontSettings', {
            getFont: api(async (details) => {
              const r = await call('settings', 'get', { path: 'fontSettings.font.' + familyOf(details) });
              return { fontId: r.value, levelOfControl: r.levelOfControl };
            }),
            setFont: api((details) => call('settings', 'set', { path: 'fontSettings.font.' + familyOf(details), value: (details || {}).fontId })),
            clearFont: api((details) => call('settings', 'clear', { path: 'fontSettings.font.' + familyOf(details) })),
            getFontList: api(() => call('fontSettings', 'getFontList', {})),
            getDefaultFontSize: defaultSize.get, setDefaultFontSize: defaultSize.set, clearDefaultFontSize: defaultSize.clear,
            getDefaultFixedFontSize: fixedSize.get, setDefaultFixedFontSize: fixedSize.set, clearDefaultFixedFontSize: fixedSize.clear,
            getMinimumFontSize: minimumSize.get, setMinimumFontSize: minimumSize.set, clearMinimumFontSize: minimumSize.clear,
            onFontChanged: mappedEvent(families.map((f) => [event('settings.onChange.fontSettings.font.' + f), f]),
              (d, family) => ({ fontId: d.value, genericFamily: family, script: 'Zyyy', levelOfControl: d.levelOfControl })),
            onDefaultFontSizeChanged: defaultSize.onChanged,
            onDefaultFixedFontSizeChanged: fixedSize.onChanged,
            onMinimumFontSizeChanged: minimumSize.onChanged,
          });

          // chrome.contentSettings, on Tuff's per-site settings.
          const contentSetting = (type) => ({
            get: api((details) => call('contentSettings', 'get', Object.assign({}, details, { type: type }))),
            set: api((details) => call('contentSettings', 'set', Object.assign({}, details, { type: type }))),
            clear: api((details) => call('contentSettings', 'clear', Object.assign({}, details, { type: type }))),
            getResourceIdentifiers: api(() => undefined),
          });
          const contentSettings = {
            Scope: { REGULAR: 'regular', INCOGNITO_SESSION_ONLY: 'incognito_session_only' },
          };
          for (const type of ['cookies', 'images', 'javascript', 'location', 'plugins', 'popups', 'notifications', 'microphone',
            'camera', 'unsandboxedPlugins', 'automaticDownloads', 'autoVerify', 'clipboard', 'sound']) {
            contentSettings[type] = contentSetting(type);
          }
          implement('contentSettings', contentSettings);

          // Firefox browser.theme, on the window's tint.
          implement('theme', {
            getCurrent: api(() => call('theme', 'getCurrent', {})),
            update: api((windowId, theme) => {
              if (windowId && typeof windowId === 'object') theme = windowId;
              return call('theme', 'update', { theme: theme || {} });
            }),
            reset: api(() => call('theme', 'reset', {})),
            onUpdated: event('theme.onUpdated'),
          });

          // Firefox browser.clipboard.
          const toBase64 = (buffer) => {
            const bytes = new Uint8Array(buffer);
            let text = '';
            for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            return btoa(text);
          };
          implement('clipboard', {
            setImageData: api((imageData, imageType) => call('clipboard', 'setImageData', { data: toBase64(imageData), imageType: imageType })),
          });

          // chrome.pageCapture: Tuff builds the MHTML from the page's Web Archive (ExtensionPageCapture).
          implement('pageCapture', {
            saveAsMHTML: api(async (details) => {
              const tabId = details && details.tabId;
              if (typeof tabId !== 'number') throw new Error('pageCapture.saveAsMHTML needs a tabId.');
              const text = await call('pageCapture', 'saveAsMHTML', { tabIndex: await indexOf(tabId) });
              return new Blob([text], { type: 'multipart/related' });
            }),
          });

          // chrome.debugger: Tuff answers the DevTools protocol commands extensions drive pages with
          // (ExtensionDebugger). Tabs only. Tuff keeps sessions by the extension's tab id, which
          // its events carry back.
          const debuggee = async (target) => {
            if (!target || typeof target !== 'object') throw new Error('A debuggee target is required.');
            if (typeof target.tabId === 'number') return { tabId: target.tabId };
            if (typeof target.targetId === 'string') {
              const found = ((await call('debugger', 'getTargets', {})) || []).find((t) => t.id === target.targetId);
              if (!found) throw new Error('No target with given id found');
              const tab = ((await root.tabs.query({})) || []).find((t) => t.index === found.tabIndex);
              if (tab) return { tabId: tab.id };
            }
            throw new Error('Tuff can only debug tabs.');
          };
          implement('debugger', {
            attach: api(async (target, requiredVersion) => {
              const t = await debuggee(target);
              let tabIndex;
              try { tabIndex = await indexOf(t.tabId); } catch (e) { throw new Error('No tab with given id ' + t.tabId + '.'); }
              return call('debugger', 'attach', { tabId: t.tabId, tabIndex: tabIndex, version: requiredVersion });
            }),
            detach: api(async (target) => call('debugger', 'detach', await debuggee(target))),
            sendCommand: api(async (target, method, commandParams) =>
              call('debugger', 'sendCommand', Object.assign(await debuggee(target), { method: method, params: commandParams || {} }))),
            getTargets: api(async () => {
              const list = (await call('debugger', 'getTargets', {})) || [];
              let tabs = [];
              try { tabs = (await root.tabs.query({})) || []; } catch (e) {}
              return list.map((t) => {
                const tab = tabs.find((x) => x.index === t.tabIndex);
                const info = Object.assign({}, t, { tabId: tab ? tab.id : undefined });
                delete info.tabIndex;
                return info;
              });
            }),
            onEvent: event('debugger.onEvent'),
            onDetach: event('debugger.onDetach'),
            DetachReason: { CANCELED_BY_USER: 'canceled_by_user', TARGET_CLOSED: 'target_closed' },
            TargetInfoType: { PAGE: 'page', BACKGROUND_PAGE: 'background_page', WORKER: 'worker', OTHER: 'other' },
          });

          // Firefox browser.find.
          const withTab = async (options) => {
            const o = Object.assign({}, options);
            if (o.tabId !== undefined && o.tabId !== null) o.tabIndex = await indexOf(o.tabId);
            delete o.tabId;
            return o;
          };
          implement('find', {
            find: api(async (queryphrase, options) => call('find', 'find', Object.assign(await withTab(options), { queryphrase: queryphrase }))),
            highlightResults: api(async (options) => call('find', 'highlightResults', await withTab(options))),
            removeHighlighting: api(async (tabId) => call('find', 'removeHighlighting', await withTab({ tabId: tabId }))),
          });

          // chrome.omnibox: the command bar sends the extension's keyword input (ExtensionOmnibox).
          implement('omnibox', {
            setDefaultSuggestion: api((suggestion) => call('omnibox', 'setDefaultSuggestion', { suggestion: suggestion || {} })),
            onInputStarted: event('omnibox.onInputStarted'),
            onInputChanged: event('omnibox.onInputChanged'),
            onInputEntered: event('omnibox.onInputEntered'),
            onInputCancelled: event('omnibox.onInputCancelled'),
            onDeleteSuggestion: event('omnibox.onDeleteSuggestion'),
            OnInputEnteredDisposition: { CURRENT_TAB: 'currentTab', NEW_FOREGROUND_TAB: 'newForegroundTab', NEW_BACKGROUND_TAB: 'newBackgroundTab' },
            DescriptionStyleType: { URL: 'url', MATCH: 'match', DIM: 'dim' },
          });

          // chrome.bookmarks, on Tuff's bookmarks (ExtensionBookmarks).
          implement('bookmarks', {
            get: api((idOrIdList) => call('bookmarks', 'get', { ids: [].concat(idOrIdList) })),
            getChildren: api((id) => call('bookmarks', 'getChildren', { id: String(id) })),
            getRecent: api((numberOfItems) => call('bookmarks', 'getRecent', { numberOfItems: numberOfItems })),
            getTree: api(() => call('bookmarks', 'getTree', {})),
            getSubTree: api((id) => call('bookmarks', 'getSubTree', { id: String(id) })),
            search: api((query) => call('bookmarks', 'search', { query: query })),
            create: api((bookmark) => call('bookmarks', 'create', { bookmark: bookmark || {} })),
            update: api((id, changes) => call('bookmarks', 'update', { id: String(id), changes: changes || {} })),
            move: api((id, destination) => call('bookmarks', 'move', { id: String(id), destination: destination || {} })),
            remove: api((id) => call('bookmarks', 'remove', { id: String(id) })),
            removeTree: api((id) => call('bookmarks', 'removeTree', { id: String(id) })),
            onCreated: event('bookmarks.onCreated'),
            onRemoved: event('bookmarks.onRemoved'),
            onChanged: event('bookmarks.onChanged'),
            onMoved: event('bookmarks.onMoved'),
            onChildrenReordered: event('bookmarks.onChildrenReordered'),
            onImportBegan: event('bookmarks.onImportBegan'),
            onImportEnded: event('bookmarks.onImportEnded'),
            MAX_WRITE_OPERATIONS_PER_HOUR: 1000000,
            MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
          });

          // chrome.readingList (ExtensionReadingList).
          implement('readingList', {
            addEntry: api((entry) => call('readingList', 'addEntry', entry || {})),
            removeEntry: api((info) => call('readingList', 'removeEntry', info || {})),
            updateEntry: api((info) => call('readingList', 'updateEntry', info || {})),
            query: api((info) => call('readingList', 'query', info || {})),
            onEntryAdded: event('readingList.onEntryAdded'),
            onEntryRemoved: event('readingList.onEntryRemoved'),
            onEntryUpdated: event('readingList.onEntryUpdated'),
          });

          // chrome.declarativeContent: Tuff keeps the rules and checks each page against them
          // (ExtensionDeclarativeContent), then asks here for the action to be turned on or off,
          // which only the extension itself can do.
          const declarative = (name) => function (options) {
            Object.assign(this, options || {});
            this.instanceType = 'declarativeContent.' + name;
          };
          // SetIcon's ImageData travels as plain pixels (base64) and is made into ImageData again here.
          const isImageData = (value) => typeof ImageData !== 'undefined' && value instanceof ImageData;
          const plainRules = (rules) => JSON.parse(JSON.stringify(rules || [], (key, value) => isImageData(value)
            ? { __tuffImage: true, width: value.width, height: value.height, data: toBase64(value.data.buffer) } : value));
          const toImageData = (p) => {
            const text = atob(p.data);
            const bytes = new Uint8ClampedArray(text.length);
            for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
            return new ImageData(bytes, p.width, p.height);
          };
          const revive = (value) => {
            if (!value || typeof value !== 'object') return value;
            if (value.__tuffImage) { try { return toImageData(value); } catch (e) { return undefined; } }
            if (Array.isArray(value)) return value.map(revive);
            const copy = {};
            for (const key of Object.keys(value)) copy[key] = revive(value[key]);
            return copy;
          };
          implement('declarativeContent', {
            PageStateMatcher: declarative('PageStateMatcher'),
            ShowAction: declarative('ShowAction'),
            ShowPageAction: declarative('ShowPageAction'),
            SetIcon: declarative('SetIcon'),
            RequestContentScript: declarative('RequestContentScript'),
            onPageChanged: {
              addRules: api(async (rules) => revive(await call('declarativeContent', 'addRules', { rules: plainRules(rules) }))),
              removeRules: api((ids) => call('declarativeContent', 'removeRules', { ids: Array.isArray(ids) ? ids : undefined })),
              getRules: api(async (ids) => revive(await call('declarativeContent', 'getRules', { ids: Array.isArray(ids) ? ids : undefined }))),
              addListener: () => undefined, removeListener: () => undefined, hasListener: () => false, hasListeners: () => false,
            },
          });
          if (declared.includes('declarativeContent') && isBackground) {
            const quietly = (result) => { if (result && result.catch) result.catch(() => {}); };
            // RequestContentScript: the files, once the page has loaded.
            const runScripts = async (tabId, script) => {
              const css = Array.isArray(script.css) ? script.css : [], js = Array.isArray(script.js) ? script.js : [];
              let scripting, tabs;
              try { scripting = root.scripting; tabs = root.tabs; } catch (e) {}
              if (scripting && typeof scripting.executeScript === 'function') {
                const target = { tabId: tabId, allFrames: !!script.allFrames };
                if (css.length) await scripting.insertCSS({ target: target, files: css });
                if (js.length) await scripting.executeScript({ target: target, files: js });
              } else if (tabs && typeof tabs.executeScript === 'function') {
                const options = { allFrames: !!script.allFrames, matchAboutBlank: !!script.matchAboutBlank };
                for (const file of css) await tabs.insertCSS(tabId, Object.assign({ file: file }, options));
                for (const file of js) await tabs.executeScript(tabId, Object.assign({ file: file }, options));
              }
            };
            event('declarativeContent.__apply').addListener((details) => {
              let action;
              try { action = root.action || root.pageAction || root.browserAction; } catch (e) {}
              if (!details || typeof details.tabId !== 'number' || details.tabId < 0) return;
              const tabId = details.tabId;
              if (action && typeof details.show === 'boolean') {
                try { quietly(details.show ? action.enable(tabId) : action.disable(tabId)); } catch (e) {}
              }
              // No icon: back to the extension's own (WebKit drops a tab's icon when given none).
              if (action && 'icon' in details) {
                const imageData = details.icon ? revive(details.icon) : null;
                try { quietly(action.setIcon(imageData ? { tabId: tabId, imageData: imageData } : { tabId: tabId, path: null })); } catch (e) {}
              }
              for (const script of Array.isArray(details.scripts) ? details.scripts : []) {
                runScripts(tabId, script).catch(() => {});
              }
            });
          }

          // Gaps inside namespaces WebKit has.
          const fill = (namespace, name, value) => {
            let object;
            try { object = root[namespace]; } catch (e) { return; }
            if (!object || typeof object !== 'object' || !absent(object, name)) return;
            add(object, name, value);
            pins.push(object);
          };
          fill('i18n', 'detectLanguage', api((text) => call('i18n', 'detectLanguage', { text: String(text || '') })));
          fill('tabs', 'discard', api(async (tabId) => {
            if (typeof tabId !== 'number') throw new Error('Tuff needs the id of the tab to discard.');
            await call('tabs', 'discard', { tabIndex: await indexOf(tabId) });
            return root.tabs.get(tabId);
          }));
          // Chrome's highlight names tabs by their index in the window, as Tuff does.
          fill('tabs', 'highlight', api(async (info) => {
            await call('tabs', 'highlight', { tabs: info && info.tabs });
            return root.windows.getLastFocused({ populate: true });
          }));
          fill('tabs', 'getZoomSettings', api(async (tabId) => {
            const tabIndex = typeof tabId === 'number' ? await indexOf(tabId) : undefined;
            return call('tabs', 'zoomSettings', tabIndex === undefined ? {} : { tabIndex });
          }));
          fill('tabs', 'setZoomSettings', api(async (tabId, settings) => {
            const hasID = typeof tabId === 'number';
            const s = hasID ? (settings || {}) : (tabId && typeof tabId === 'object' ? tabId : {});
            const tabIndex = hasID ? await indexOf(tabId) : undefined;
            return call('tabs', 'setZoomSettings', {
              tabIndex,
              mode: s.mode,
              scope: s.scope,
            });
          }));
          fill('tabs', 'print', api(() => call('tabs', 'print', {})));
          fill('tabs', 'warmup', api(() => undefined));
          // Firefox: a picture of any tab (captureVisibleTab only does the selected one), and
          // saving the page as a PDF. Print preview is part of the Mac's print panel.
          fill('tabs', 'captureTab', api(async (tabId, options) => {
            if (tabId && typeof tabId === 'object') { options = tabId; tabId = undefined; }
            const tabIndex = typeof tabId === 'number' ? await indexOf(tabId) : undefined;
            return call('tabs', 'captureTab', { tabIndex: tabIndex, options: options || {} });
          }));
          fill('tabs', 'saveAsPDF', api((pageSettings) => call('tabs', 'saveAsPDF', pageSettings || {})));
          fill('tabs', 'printPreview', api(() => call('tabs', 'print', {})));
          // Firefox's page action shows and hides; WebKit's enables and disables.
          let pageAction;
          try { pageAction = root.pageAction; } catch (e) {}
          if (pageAction && typeof pageAction.enable === 'function') {
            fill('pageAction', 'show', api((tabId) => pageAction.enable(tabId)));
            fill('pageAction', 'hide', api((tabId) => pageAction.disable(tabId)));
            fill('pageAction', 'isShown', api((details) => pageAction.isEnabled(details)));
          }
          // Badge colours: Tuff draws the badge, so it needs them too (ExtensionBadgeColors).
          const badgeTab = async (details) => (details && typeof details.tabId === 'number') ? indexOf(details.tabId) : undefined;
          for (const name of ['action', 'browserAction']) {
            let action;
            try { action = root[name]; } catch (e) { continue; }
            if (!action || typeof action !== 'object') continue;
            const setBackground = action.setBadgeBackgroundColor;
            if (typeof setBackground === 'function' && !setBackground.__tuff) {
              const wrapped = api(async (details) => {
                await setBackground(details);
                await call('action', 'setBadgeColor', { kind: 'background', color: details && details.color, tabIndex: await badgeTab(details) });
              });
              wrapped.__tuff = true;
              add(action, 'setBadgeBackgroundColor', wrapped);
            }
            fill(name, 'setBadgeTextColor', api(async (details) =>
              call('action', 'setBadgeColor', { kind: 'text', color: details && details.color, tabIndex: await badgeTab(details) })));
            fill(name, 'getBadgeTextColor', api(async (details) => call('action', 'getBadgeTextColor', { tabIndex: await badgeTab(details) })));
            fill(name, 'getUserSettings', api(() => call('action', 'getUserSettings', {})));
            fill(name, 'onUserSettingsChanged', event('action.onUserSettingsChanged'));
            // Chrome's isEnabled takes a tab id; WebKit wants Firefox's `{ tabId }`.
            const isEnabled = action.isEnabled;
            if (typeof isEnabled === 'function' && !isEnabled.__tuff) {
              const tolerant = (details, ...rest) => isEnabled(typeof details === 'number' ? { tabId: details } : details, ...rest);
              tolerant.__tuff = true;
              add(action, 'isEnabled', tolerant);
            }
            pins.push(action);
          }
          // WebKit doesn't fire runtime.onInstalled when an extension is first added, so Tuff sends
          // it as well. Each listener hears it once in a worker's life, from whichever comes first.
          let installed;
          try { installed = root.runtime.onInstalled; } catch (e) {}
          if (installed && typeof installed.addListener === 'function' && !installed.__tuff) {
            const ours = event('runtime.onInstalled');
            const once = new Map();
            const addListener = installed.addListener, removeListener = installed.removeListener, hasListener = installed.hasListener;
            add(installed, 'addListener', (fn, ...rest) => {
              if (typeof fn !== 'function' || once.has(fn)) return addListener(fn, ...rest);
              let heard = false;
              const wrapper = (details) => {
                if (heard) return undefined;
                heard = true;
                return fn(details);
              };
              once.set(fn, wrapper);
              addListener(wrapper, ...rest);
              ours.addListener(wrapper);
            });
            add(installed, 'removeListener', (fn) => {
              const wrapper = once.get(fn);
              if (!wrapper) return removeListener(fn);
              once.delete(fn);
              ours.removeListener(wrapper);
              return removeListener(wrapper);
            });
            add(installed, 'hasListener', (fn) => once.has(fn) || hasListener(fn));
            add(installed, '__tuff', true);
            pins.push(installed);
          }
          fill('runtime', 'requestUpdateCheck', api(() => call('runtime', 'requestUpdateCheck', {})));
          // An extension that listens is told of its update, which then waits for runtime.reload()
          // or Tuff's next launch, as in Chrome. WebKit's reload can't be wrapped, but it ends with
          // onInstalled, so the background asks for the waiting update then.
          const updateAvailable = event('runtime.onUpdateAvailable');
          let reloadHooked = false;
          fill('runtime', 'onUpdateAvailable', Object.assign({}, updateAvailable, {
            addListener: (fn, filter) => {
              updateAvailable.addListener(fn, filter);
              if (reloadHooked || !isBackground || !installed) return;
              reloadHooked = true;
              root.runtime.onInstalled.addListener(() => { call('runtime', 'installWaitingUpdate', {}).catch(() => {}); });
            },
          }));
          fill('runtime', 'onBrowserUpdateAvailable', event('runtime.onBrowserUpdateAvailable'));
          // The extension's open pages (offscreen document, tabs, side panel) and background.
          fill('runtime', 'getContexts', api(async (filter) => {
            const f = filter || {};
            const found = (await call('runtime', 'getContexts', {})) || [];
            let tabs = [];
            if (found.some((c) => c.tabIndex >= 0)) { try { tabs = (await root.tabs.query({})) || []; } catch (e) {} }
            const windowId = await focusedWindowId();
            const list = found.map((c) => {
              const tab = c.tabIndex >= 0 ? tabs.find((t) => t.index === c.tabIndex) : null;
              const context = Object.assign({}, c, {
                tabId: tab ? tab.id : -1,
                windowId: tab || c.contextType === 'SIDE_PANEL' || c.contextType === 'POPUP' ? windowId : -1,
              });
              delete context.tabIndex;
              return context;
            });
            const keep = (key, value) => !Array.isArray(f[key]) || f[key].includes(value);
            return list.filter((c) => keep('contextTypes', c.contextType) && keep('contextIds', c.contextId)
              && keep('tabIds', c.tabId) && keep('windowIds', c.windowId) && keep('documentIds', c.documentId)
              && keep('frameIds', c.frameId) && keep('documentUrls', c.documentUrl) && keep('documentOrigins', c.documentOrigin)
              && (typeof f.incognito !== 'boolean' || f.incognito === c.incognito));
          }));
          if (absent(root.runtime, 'ContextType')) {
            add(root.runtime, 'ContextType', {
              TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT',
              SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS',
            });
          }
          // runtime.getPackageDirectoryEntry: read-only DirectoryEntry/FileEntry tree over the extension bundle.
          const pkgFilesystem = { name: 'crxfs', root: null };
          const makePackageEntry = (meta) => {
            const fullPath = meta.fullPath || '/';
            const name = meta.name || '';
            const base = {
              isFile: !!meta.isFile,
              isDirectory: !!meta.isDirectory,
              name,
              fullPath,
              filesystem: pkgFilesystem,
              toURL: () => {
                try { return root.runtime.getURL(fullPath.replace(/^\\/+/, '')); } catch (e) { return fullPath; }
              },
              getMetadata: (success, error) => {
                call('runtime', 'packageStat', { path: fullPath }).then((m) => {
                  if (typeof success === 'function') success({ size: m.size || 0, modificationTime: new Date(m.modificationTime || 0) });
                }, (err) => { if (typeof error === 'function') error(err); });
              },
              getParent: (success, error) => {
                const parentPath = fullPath === '/' ? '/' : (fullPath.replace(/\\/[^/]+$/, '') || '/');
                call('runtime', 'packageStat', { path: parentPath }).then((m) => {
                  if (typeof success === 'function') success(makePackageEntry(m));
                }, (err) => { if (typeof error === 'function') error(err); });
              },
            };
            if (meta.isFile) {
              base.file = (success, error) => {
                const url = base.toURL();
                fetch(url).then((res) => res.blob()).then((blob) => {
                  const file = typeof File === 'function'
                    ? new File([blob], name, { type: blob.type, lastModified: meta.modificationTime || Date.now() })
                    : blob;
                  if (typeof success === 'function') success(file);
                }, (err) => { if (typeof error === 'function') error(err); });
              };
            } else {
              const resolveChild = (rel) => {
                const p = String(rel || '');
                if (p.startsWith('/')) return p;
                return (fullPath === '/' ? '' : fullPath) + '/' + p;
              };
              const lookup = (expectDir) => (path, options, success, error) => {
                if (typeof options === 'function') { error = success; success = options; options = {}; }
                if (options && options.create) {
                  if (typeof error === 'function') error(new DOMException('Extension package is read-only.', 'NoModificationAllowedError'));
                  return;
                }
                call('runtime', 'packageStat', { path: resolveChild(path) }).then((m) => {
                  if (!!m.isDirectory !== expectDir) {
                    if (typeof error === 'function') error(new DOMException('Entry type mismatch.', 'TypeMismatchError'));
                    return;
                  }
                  if (typeof success === 'function') success(makePackageEntry(m));
                }, (err) => { if (typeof error === 'function') error(err); });
              };
              base.getFile = lookup(false);
              base.getDirectory = lookup(true);
              base.createReader = () => {
                let done = false;
                return {
                  readEntries: (success, error) => {
                    if (done) { if (typeof success === 'function') success([]); return; }
                    done = true;
                    call('runtime', 'packageList', { path: fullPath }).then((list) => {
                      if (typeof success === 'function') success((list || []).map(makePackageEntry));
                    }, (err) => { if (typeof error === 'function') error(err); });
                  },
                };
              };
            }
            return base;
          };
          pkgFilesystem.root = makePackageEntry({ name: '', fullPath: '/', isDirectory: true, isFile: false });
          fill('runtime', 'getPackageDirectoryEntry', api(() => pkgFilesystem.root));

          // cookies.getPartitionKey
          fill('cookies', 'getPartitionKey', api(async (details) => {
            const d = details && typeof details === 'object' ? Object.assign({}, details) : {};
            if (typeof d.tabId === 'number') d.tabIndex = await indexOf(d.tabId);
            return call('cookies', 'getPartitionKey', d);
          }));

          // chrome.storage.managed / browser.storage.managed (ExtensionManagedStorage)
          let storage;
          try { storage = root.storage; } catch (e) {}
          if (storage && typeof storage === 'object' && absent(storage, 'managed')) {
            const managed = {
              get: api((keys) => call('storage.managed', 'get', { keys: keys === undefined ? null : keys })),
              getKeys: api(() => call('storage.managed', 'getKeys', {})),
              getBytesInUse: api((keys) => call('storage.managed', 'getBytesInUse', { keys: keys === undefined ? null : keys })),
              onChanged: event('storage.managed.onChanged'),
            };
            add(storage, 'managed', managed);
            pins.push(storage);
          }

          // declarativeNetRequest.getAvailableStaticRuleCount / testMatchOutcome / updateStaticRules / getDisabledRuleIds
          let dnr;
          try { dnr = root.declarativeNetRequest; } catch (e) {}
          if (dnr && typeof dnr === 'object') {
            const enabledRulesets = async () => {
              if (typeof dnr.getEnabledRulesets !== 'function') return undefined;
              try { return await dnr.getEnabledRulesets(); } catch (e) { return undefined; }
            };
            fill('declarativeNetRequest', 'getAvailableStaticRuleCount', api(async () =>
              call('declarativeNetRequest', 'getAvailableStaticRuleCount', { enabledRulesetIds: await enabledRulesets() })));
            fill('declarativeNetRequest', 'testMatchOutcome', api(async (request) => {
              let dynamicRules = [], sessionRules = [];
              try { if (typeof dnr.getDynamicRules === 'function') dynamicRules = (await dnr.getDynamicRules()) || []; } catch (e) {}
              try { if (typeof dnr.getSessionRules === 'function') sessionRules = (await dnr.getSessionRules()) || []; } catch (e) {}
              return call('declarativeNetRequest', 'testMatchOutcome', {
                request: request || {},
                enabledRulesetIds: await enabledRulesets(),
                dynamicRules,
                sessionRules,
              });
            }));
            fill('declarativeNetRequest', 'updateStaticRules', api(async (options) => {
              const o = options && typeof options === 'object' ? options : {};
              return call('declarativeNetRequest', 'updateStaticRules', {
                rulesetId: o.rulesetId,
                disableRuleIds: Array.isArray(o.disableRuleIds) ? o.disableRuleIds : [],
                enableRuleIds: Array.isArray(o.enableRuleIds) ? o.enableRuleIds : [],
              });
            }));
            fill('declarativeNetRequest', 'getDisabledRuleIds', api(async (options) => {
              const o = options && typeof options === 'object' ? options : {};
              return call('declarativeNetRequest', 'getDisabledRuleIds', { rulesetId: o.rulesetId });
            }));
          }

          // chrome.webAuthenticationProxy (ExtensionWebAuthn)
          implement('webAuthenticationProxy', {
            attach: api(() => call('webAuthenticationProxy', 'attach', {})),
            detach: api(() => call('webAuthenticationProxy', 'detach', {})),
            completeCreateRequest: api((details) => call('webAuthenticationProxy', 'completeCreateRequest', details || {})),
            completeGetRequest: api((details) => call('webAuthenticationProxy', 'completeGetRequest', details || {})),
            completeIsUvpaaRequest: api((details) => call('webAuthenticationProxy', 'completeIsUvpaaRequest', details || {})),
            onCreateRequest: event('webAuthenticationProxy.onCreateRequest'),
            onGetRequest: event('webAuthenticationProxy.onGetRequest'),
            onIsUvpaaRequest: event('webAuthenticationProxy.onIsUvpaaRequest'),
            onRemoteSessionStateChange: event('webAuthenticationProxy.onRemoteSessionStateChange'),
            onRequestCanceled: event('webAuthenticationProxy.onRequestCanceled'),
          });

          // Firefox menus.onShown / menus.onHidden / menus.overrideContext + tab/bookmark menu item relay
          fill('menus', 'onShown', event('menus.onShown'));
          fill('menus', 'onHidden', event('menus.onHidden'));
          fill('menus', 'overrideContext', api(async (options) => {
            const o = options && typeof options === 'object' ? Object.assign({}, options) : {};
            if (typeof o.tabId === 'number') {
              o.tabIndex = await indexOf(o.tabId);
            }
            return call('menus', 'overrideContext', o);
          }));
          for (const menuNs of ['menus', 'contextMenus']) {
            let m;
            try { m = root[menuNs]; } catch (e) { continue; }
            if (!m || typeof m !== 'object') continue;
            if (typeof m.create === 'function' && !m.create.__tuffOverrideTrack) {
              const prevCreate = m.create;
              const tracked = (props, ...rest) => {
                const ctxs = props && Array.isArray(props.contexts) ? props.contexts : [];
                if (ctxs.includes('tab') || ctxs.includes('bookmark') || ctxs.includes('all')) {
                  call('menus', 'registerItem', {
                    id: props.id, title: props.title || '', contexts: ctxs,
                    enabled: props.enabled !== false, type: props.type || 'normal',
                  }).catch(() => {});
                }
                try { return prevCreate(props, ...rest); } catch (err) {
                  // WebKit rejects Firefox-only contexts like 'bookmark' or 'tab'; keep our native item.
                  if (ctxs.includes('bookmark') || ctxs.includes('tab')) return props && props.id;
                  throw err;
                }
              };
              tracked.__tuff = true;
              tracked.__tuffOverrideTrack = true;
              add(m, 'create', tracked);
            }
            if (typeof m.remove === 'function' && !m.remove.__tuffOverrideTrack) {
              const prevRemove = m.remove;
              const trackedRemove = (id, ...rest) => {
                call('menus', 'removeItem', { id: String(id) }).catch(() => {});
                return prevRemove(id, ...rest);
              };
              trackedRemove.__tuffOverrideTrack = true;
              add(m, 'remove', trackedRemove);
            }
            if (typeof m.removeAll === 'function' && !m.removeAll.__tuffOverrideTrack) {
              const prevRemoveAll = m.removeAll;
              const trackedRemoveAll = (...rest) => {
                call('menus', 'removeItem', {}).catch(() => {});
                return prevRemoveAll(...rest);
              };
              trackedRemoveAll.__tuffOverrideTrack = true;
              add(m, 'removeAll', trackedRemoveAll);
            }
            if (m.onClicked && typeof m.onClicked.addListener === 'function' && !m.onClicked.__tuffCustomWired) {
              const origAdd = m.onClicked.addListener;
              const origRem = m.onClicked.removeListener;
              const customEv = event('menus.onCustomClicked');
              add(m.onClicked, 'addListener', (fn, ...rest) => {
                if (typeof fn === 'function') customEv.addListener(fn);
                return origAdd(fn, ...rest);
              });
              add(m.onClicked, 'removeListener', (fn, ...rest) => {
                if (typeof fn === 'function') customEv.removeListener(fn);
                return origRem(fn, ...rest);
              });
              m.onClicked.__tuffCustomWired = true;
            }
            pins.push(m);
          }
          // Only for Firefox extensions: Chrome ones often take its presence to mean Firefox.
          let manifest = {};
          try { manifest = root.runtime.getManifest() || {}; } catch (e) {}
          if ((manifest.browser_specific_settings && manifest.browser_specific_settings.gecko) || (manifest.applications && manifest.applications.gecko)) {
            fill('runtime', 'getBrowserInfo', api(() => call('runtime', 'getBrowserInfo', {})));
            fill('commands', 'openShortcutSettings', api(() => call('commands', 'openShortcutSettings', {})));
            // An extension changing its own shortcuts. WebKit reports the new keys itself; new
            // descriptions are Tuff's to fill in.
            fill('commands', 'update', api((detail) => call('commands', 'update', { detail: detail || {} })));
            fill('commands', 'reset', api((name) => call('commands', 'reset', { name: name })));
            let commands;
            try { commands = root.commands; } catch (e) {}
            const getAll = commands && commands.getAll;
            if (typeof getAll === 'function' && !getAll.__tuff) {
              const withDescriptions = api(async () => {
                const list = (await getAll()) || [];
                const descriptions = (await call('commands', 'descriptions', {})) || {};
                return list.map((c) => descriptions[c.name] === undefined ? c : Object.assign({}, c, { description: descriptions[c.name] }));
              });
              withDescriptions.__tuff = true;
              add(commands, 'getAll', withDescriptions);
              pins.push(commands);
            }
          }

          // Scripts registered at run time with inline code (WebKit only registers files). Tuff
          // adds them to every tab as user scripts limited to the requested URLs; see
          // ExtensionContentScripts. uBlock Origin delivers its scriptlets this way.
          const scriptHandle = (id) => ({
            unregister: api(() => call('contentScripts', 'unregister', { id: id })),
          });
          implement('contentScripts', {
            register: api(async (options) => scriptHandle(await call('contentScripts', 'register', options || {}))),
          });
          implement('userScripts', {
            // Chrome (MV3) takes a list and returns nothing; Firefox (MV2) takes one script and
            // returns a handle.
            register: api(async (scripts) => {
              if (Array.isArray(scripts)) return call('userScripts', 'register', { scripts: scripts });
              return scriptHandle(await call('userScripts', 'registerLegacy', scripts || {}));
            }),
            update: api((scripts) => call('userScripts', 'update', { scripts: scripts || [] })),
            unregister: api((filter) => call('userScripts', 'unregister', { ids: filter && filter.ids })),
            getScripts: api(async (filter) => (await call('userScripts', 'getScripts', { ids: filter && filter.ids })) || []),
            configureWorld: api((properties) => call('userScripts', 'configureWorld', { properties: properties || {} })),
            resetWorldConfiguration: api((worldId) => call('userScripts', 'resetWorldConfiguration', { worldId: worldId })),
            getWorldConfigurations: api(async () => (await call('userScripts', 'getWorldConfigurations', {})) || []),
            execute: api(async (injection) => {
              const details = Object.assign({}, injection);
              if (details.target && typeof details.target === 'object') {
                const target = Object.assign({}, details.target);
                if (typeof target.tabId === 'number') target.tabIndex = await indexOf(target.tabId);
                details.target = target;
              }
              return (await call('userScripts', 'execute', details)) || [];
            }),
            onBeforeScript: event('userScripts.onBeforeScript'),
            ExecutionWorld: { MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' },
          });

          // runtime.onUserScriptMessage / runtime.onUserScriptConnect: messaging from user scripts
          // configured with `userScripts.configureWorld({ messaging: true })`.
          const usMessageListeners = new Set();
          const usMessageSource = event('runtime.__userScriptMessage');
          const onUserScriptMessageRaw = (message, sender, requestId) => {
            let responded = false;
            const sendResponse = (response) => {
              if (responded) return;
              responded = true;
              call('userScripts', 'replyMessage', { requestId, response: response === undefined ? null : response }).catch(() => {});
            };
            let asyncPending = false;
            for (const fn of [...usMessageListeners]) {
              try {
                const result = fn(message, sender, sendResponse);
                if (result === true) {
                  asyncPending = true;
                } else if (result && typeof result.then === 'function') {
                  asyncPending = true;
                  result.then(sendResponse, (err) => {
                    if (responded) return;
                    responded = true;
                    call('userScripts', 'replyMessage', { requestId, error: String((err && err.message) || err) }).catch(() => {});
                  });
                }
              } catch (e) {}
              if (responded) break;
            }
            if (!responded && !asyncPending) sendResponse(undefined);
          };
          fill('runtime', 'onUserScriptMessage', {
            addListener: (fn) => {
              if (typeof fn !== 'function') return;
              const first = usMessageListeners.size === 0;
              usMessageListeners.add(fn);
              if (first) usMessageSource.addListener(onUserScriptMessageRaw);
            },
            removeListener: (fn) => {
              usMessageListeners.delete(fn);
              if (usMessageListeners.size === 0) usMessageSource.removeListener(onUserScriptMessageRaw);
            },
            hasListener: (fn) => usMessageListeners.has(fn),
            hasListeners: () => usMessageListeners.size > 0,
          });

          const usConnectListeners = new Set();
          const usPorts = new Map();
          const usConnectSource = event('runtime.__userScriptConnect');
          const usPortMessageSource = event('runtime.__userScriptPortMessage');
          const usPortDisconnectSource = event('runtime.__userScriptPortDisconnect');
          const makeLocalEvent = () => {
            const set = new Set();
            return {
              addListener: (fn) => { if (typeof fn === 'function') set.add(fn); },
              removeListener: (fn) => { set.delete(fn); },
              hasListener: (fn) => set.has(fn),
              hasListeners: () => set.size > 0,
              _fire: (...args) => { for (const fn of [...set]) { try { fn(...args); } catch (e) {} } },
            };
          };
          const onUserScriptConnectRaw = (portId, name, sender) => {
            const onMessage = makeLocalEvent();
            const onDisconnect = makeLocalEvent();
            const port = {
              name: name || '',
              sender: sender || {},
              onMessage,
              onDisconnect,
              _disconnected: false,
              postMessage: (msg) => {
                if (port._disconnected) throw new Error('Attempting to use a disconnected port object');
                call('userScripts', 'portMessage', { portId, message: msg === undefined ? null : msg }).catch(() => {});
              },
              disconnect: () => {
                if (port._disconnected) return;
                port._disconnected = true;
                usPorts.delete(portId);
                call('userScripts', 'portDisconnect', { portId }).catch(() => {});
              },
            };
            usPorts.set(portId, port);
            for (const fn of [...usConnectListeners]) { try { fn(port); } catch (e) {} }
          };
          const onUserScriptPortMessageRaw = (portId, msg) => {
            const port = usPorts.get(portId);
            if (port && !port._disconnected) port.onMessage._fire(msg, port);
          };
          const onUserScriptPortDisconnectRaw = (portId) => {
            const port = usPorts.get(portId);
            if (!port) return;
            port._disconnected = true;
            usPorts.delete(portId);
            port.onDisconnect._fire(port);
          };
          fill('runtime', 'onUserScriptConnect', {
            addListener: (fn) => {
              if (typeof fn !== 'function') return;
              const first = usConnectListeners.size === 0;
              usConnectListeners.add(fn);
              if (first) {
                usConnectSource.addListener(onUserScriptConnectRaw);
                usPortMessageSource.addListener(onUserScriptPortMessageRaw);
                usPortDisconnectSource.addListener(onUserScriptPortDisconnectRaw);
              }
            },
            removeListener: (fn) => {
              usConnectListeners.delete(fn);
              if (usConnectListeners.size === 0) {
                usConnectSource.removeListener(onUserScriptConnectRaw);
                usPortMessageSource.removeListener(onUserScriptPortMessageRaw);
                usPortDisconnectSource.removeListener(onUserScriptPortDisconnectRaw);
              }
            },
            hasListener: (fn) => usConnectListeners.has(fn),
            hasListeners: () => usConnectListeners.size > 0,
          });
        }
      }

      // Firefox menus.getTargetElement(targetElementId): synchronous lookup of the right-clicked
      // element in content scripts and extension pages, keyed by the same coordinate ID as ExtensionMenus.
      if (typeof document !== 'undefined' && typeof WeakRef === 'function') {
        const menuTargets = new Map();
        const menuOrder = [];
        document.addEventListener('contextmenu', (e) => {
          const el = e.target instanceof Element ? e.target : (e.target && e.target.parentElement) || null;
          if (!el) return;
          const x = Math.max(0, Math.round(e.clientX || 0)) & 0x7FFF;
          const y = Math.max(0, Math.round(e.clientY || 0)) & 0x7FFF;
          const id = ((x << 15) | y) || 1;
          menuTargets.set(id, new WeakRef(el));
          menuOrder.push(id);
          if (menuOrder.length > 32) menuTargets.delete(menuOrder.shift());
        }, { capture: true, passive: true });
        const getTargetElement = (targetElementId) => {
          const ref = menuTargets.get(targetElementId);
          return (ref && ref.deref()) || null;
        };
        for (const { root } of roots) {
          for (const nsName of ['menus', 'contextMenus']) {
            let ns;
            try { ns = root[nsName]; } catch (e) {}
            if (!ns && nsName === 'menus') {
              ns = {};
              add(root, 'menus', ns);
            }
            if (ns && typeof ns === 'object' && absent(ns, 'getTargetElement')) {
              add(ns, 'getTargetElement', getTargetElement);
              pins.push(ns);
            }
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
