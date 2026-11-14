import AppKit

enum MainMenu {
    private static func key(_ code: Int) -> String { String(UnicodeScalar(UInt32(code)).map(Character.init) ?? " ") }

    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func item(
            _ title: String, _ action: Selector?, _ keyEquivalent: String = "",
            _ modifiers: NSEvent.ModifierFlags = .command, own: Bool = true, tag: Int = 0
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            if own { item.target = target }
            return item
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }

        let sep = { NSMenuItem.separator() }

        /// A submenu inside another menu (Edit → Spelling and Grammar).
        func nested(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }

        /// ⌘N opens a new tab too (there is one browser window), without a second menu line.
        let newTabOnCommandN = item("New Tab", #selector(AppDelegate.newTab(_:)), "n")
        newTabOnCommandN.isHidden = true
        newTabOnCommandN.allowsKeyEquivalentWhenHidden = true

        // App
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        _ = submenu("Tuff", [
            item("About Tuff", #selector(AppDelegate.showAbout(_:))),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))),
            sep(),
            item("Settings…", #selector(AppDelegate.showSettingsWindow(_:)), ","),
            item("Extensions…", #selector(AppDelegate.showExtensions(_:)), "e", [.command, .shift]),
            sep(),
            servicesItem,
            sep(),
            item("Hide Tuff", #selector(NSApplication.hide(_:)), "h", own: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], own: false),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), own: false),
            sep(),
            item("Quit Tuff", #selector(NSApplication.terminate(_:)), "q", own: false),
        ])

        // File
        _ = submenu("File", [
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t"),
            item("New Incognito Window", #selector(AppDelegate.newIncognitoWindow(_:)), "n", [.command, .shift]),
            item("New Space", #selector(AppDelegate.newSpace(_:)), "n", [.command, .control]),
            item("New Folder", #selector(AppDelegate.newFolder(_:)), "n", [.command, .option]),
            newTabOnCommandN,
            item("Open Location…", #selector(AppDelegate.openLocation(_:)), "l"),
            item("Open File…", #selector(AppDelegate.openFile(_:)), "o"),
            sep(),
            item("Close Tab", #selector(AppDelegate.closeTab(_:)), "w"),
            item("Close Window", #selector(AppDelegate.closeWindow(_:)), "w", [.command, .shift]),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
            sep(),
            item("Save Page As…", #selector(AppDelegate.savePageAs(_:)), "s", [.command, .shift]),
            sep(),
            item("Import from Another Browser…", #selector(AppDelegate.showImport(_:))),
            sep(),
            item("Print…", #selector(AppDelegate.printPage(_:)), "p"),
        ])

        // Edit
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", own: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], own: false),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x", own: false),
            item("Copy", #selector(NSText.copy(_:)), "c", own: false),
            item("Paste", #selector(NSText.paste(_:)), "v", own: false),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift], own: false),
            item("Delete", #selector(NSText.delete(_:)), own: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", own: false),
            sep(),
            item("Find…", #selector(AppDelegate.findInPage(_:)), "f"),
            item("Find Next", #selector(AppDelegate.findNext(_:)), "g"),
            item("Find Previous", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift]),
            item("Copy Link", #selector(AppDelegate.copyLink(_:)), "c", [.command, .shift]),
            sep(),
            nested("Spelling and Grammar", [
                item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":", own: false),
                item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";", own: false),
                sep(),
                item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), own: false),
                item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)), own: false),
                item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), own: false),
            ]),
            nested("Substitutions", [
                item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), own: false),
                sep(),
                item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:)), own: false),
                item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), own: false),
                item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), own: false),
                item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:)), own: false),
                item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)), own: false),
            ]),
            nested("Speech", [
                item("Start Speaking", #selector(NSTextView.startSpeaking(_:)), own: false),
                item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:)), own: false),
            ]),
        ])

        // View
        _ = submenu("View", [
            item("Toggle Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "s"),
            item("Toggle Extension Panel", #selector(AppDelegate.toggleSidePanel(_:)), "s", [.command, .option]),
            sep(),
            item("New Split View…", #selector(AppDelegate.toggleSplit(_:)), "\\"),
            item("Switch Split Side", #selector(AppDelegate.focusOtherSplitSide(_:)), "\\", [.command, .option]),
            item("Swap Split Sides", #selector(AppDelegate.swapSplitSides(_:))),
            sep(),
            item("Reload Page", #selector(AppDelegate.reload(_:)), "r"),
            item("Reload From Origin", #selector(AppDelegate.reloadFromOrigin(_:)), "r", [.command, .shift]),
            item("Stop", #selector(AppDelegate.stopLoading(_:)), "."),
            sep(),
            item("View Source", #selector(AppDelegate.viewSource(_:)), "u", [.command, .option]),
            item("Show Downloads", #selector(AppDelegate.showDownloads(_:)), "l", [.command, .option]),
            sep(),
            item("Actual Size", #selector(AppDelegate.zoomReset(_:)), "0"),
            item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "="),
            item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"),
            sep(),
            item("Enter Reader Mode", #selector(AppDelegate.toggleReader(_:)), "r", [.command, .option]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], own: false),
            item("Picture in Picture", #selector(AppDelegate.togglePictureInPicture(_:)), "p", [.command, .control]),
            sep(),
            item("Web Inspector", #selector(AppDelegate.showInspector(_:)), "i", [.command, .option]),
        ])

        // History
        _ = submenu("History", [
            item("Back", #selector(AppDelegate.goBack(_:)), "["),
            item("Forward", #selector(AppDelegate.goForward(_:)), "]"),
            sep(),
            item("Show All History", #selector(AppDelegate.showHistory(_:)), "y"),
            item("Clear History…", #selector(AppDelegate.clearHistory(_:))),
            item("Import History & Bookmarks…", #selector(AppDelegate.showImport(_:))),
        ])

        // Tabs
        var tabItems: [NSMenuItem] = [
            item("Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", [.control]),
            item("Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift]),
            item("Next Tab", #selector(AppDelegate.nextTab(_:)), key(NSDownArrowFunctionKey), [.command, .option]),
            item("Previous Tab", #selector(AppDelegate.previousTab(_:)), key(NSUpArrowFunctionKey), [.command, .option]),
            sep(),
            item("Pin Tab", #selector(AppDelegate.togglePin(_:)), "d"),
            item("Duplicate Tab", #selector(AppDelegate.duplicateTab(_:))),
            item("Mute Tab", #selector(AppDelegate.toggleMute(_:)), "m", [.command, .shift]),
            sep(),
        ]
        for n in 1...9 {
            tabItems.append(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(AppDelegate.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        _ = submenu("Tabs", tabItems)

        // Spaces
        var spaceItems: [NSMenuItem] = [
            item("Next Space", #selector(AppDelegate.nextSpace(_:)), key(NSRightArrowFunctionKey), [.command, .option]),
            item("Previous Space", #selector(AppDelegate.previousSpace(_:)), key(NSLeftArrowFunctionKey), [.command, .option]),
            sep(),
        ]
        for n in 1...9 {
            spaceItems.append(item("Space \(n)", #selector(AppDelegate.selectSpaceByNumber(_:)), "\(n)", [.control], tag: n))
        }
        _ = submenu("Spaces", spaceItems)

        // Window
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", own: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), own: false),
            sep(),
            item("Show Browser Window", #selector(AppDelegate.showBrowserWindow(_:)), "0", [.command, .shift]),
            sep(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), own: false),
        ])
        NSApp.windowsMenu = window

        // Help (macOS adds its menu search at the top)
        let help = submenu("Help", [
            item("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:)), "/", [.command, .shift]),
        ])
        NSApp.helpMenu = help

        return main
    }
}
