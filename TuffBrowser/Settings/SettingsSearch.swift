import SwiftUI

// MARK: - Router

/// A setting picked in search: its page scrolls to it and it lights up for a moment.
struct SettingsTarget: Equatable {
    let tab: SettingsTab
    /// The row's title, or `group:` + a group's title (see `settingsAnchor`).
    let anchor: String
    /// Picking the same result twice should still scroll and flash.
    let token = UUID()
}

/// Where the setting search picked sits on its page, reported by that setting alone (see
/// `SettingsAnchor`) so `SettingsPage` can scroll to it.
struct SettingsTargetFrame: Equatable {
    let token: UUID
    /// Top of the setting, measured from the top of the page's content.
    let y: CGFloat

    static let space = "SettingsPageContent"
}

struct SettingsTargetFrameKey: PreferenceKey {
    static let defaultValue: SettingsTargetFrame? = nil
    static func reduce(value: inout SettingsTargetFrame?, nextValue: () -> SettingsTargetFrame?) {
        value = value ?? nextValue()
    }
}

@Observable
final class SettingsRouter {
    private static let lastTabKey = "TuffSettingsLastTab"

    /// The page on show. Remembered, so ⌘, reopens where you were.
    private(set) var tab: SettingsTab
    private(set) var target: SettingsTarget?
    /// The site whose settings Websites shows (an origin, `https://example.com`), or nil for
    /// the list of sites.
    var site: String?
    /// What's typed in the sidebar's search field.
    var query = ""

    init() {
        tab = UserDefaults.standard.string(forKey: Self.lastTabKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    /// Shows a page, optionally scrolling to one setting on it and lighting it up.
    func go(_ tab: SettingsTab, anchor: String? = nil, site: String? = nil) {
        self.site = site
        // Set the target first: the page being left ignores it (it's for another page), and the
        // page coming in finds it when it appears.
        target = anchor.map { SettingsTarget(tab: tab, anchor: $0) }
        self.tab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
    }
}

// MARK: - Anchors

/// Marks a row or group as somewhere search can take you: the page scrolls it into view and it
/// glows in the accent colour for a moment.
private struct SettingsAnchor: ViewModifier {
    let name: String
    let radius: CGFloat
    let inset: CGFloat
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    @Environment(\.accent) private var accent
    @State private var lit = false

    /// The search target, when it's this setting.
    private var target: SettingsTarget? {
        guard let target = router?.target, target.tab == router?.tab, target.anchor == name else { return nil }
        return target
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(accent.opacity(lit ? 0.26 : 0))
                    .padding(inset)
                    .allowsHitTesting(false)
            }
            .background {
                // Only the picked setting measures itself, so ordinary scrolling costs nothing.
                if let target {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SettingsTargetFrameKey.self,
                            value: SettingsTargetFrame(token: target.token, y: geo.frame(in: .named(SettingsTargetFrame.space)).minY)
                        )
                    }
                }
            }
            .onAppear(perform: check)
            .onChange(of: router?.target) { check() }
    }

    private func check() {
        guard target != nil else { return }
        // Wait for the page to scroll there before lighting up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { lit = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                withAnimation(.easeInOut(duration: 0.9)) { lit = false }
            }
        }
    }
}

extension View {
    /// See `SettingsAnchor`. Rows and titled groups get one automatically.
    func settingsAnchor(_ name: String, radius: CGFloat = 9, inset: CGFloat = 3) -> some View {
        modifier(SettingsAnchor(name: name, radius: radius, inset: inset))
    }
}

// MARK: - Index

/// One setting the sidebar search can find. `title` is what the result says, which can be
/// clearer out of context than the row's own label ("Tab position" rather than "Main browsing").
struct SettingsSearchEntry: Identifiable {
    let title: String
    let tab: SettingsTab
    /// The group heading it sits under, shown in the result as "Page › Group".
    let group: String?
    /// Where to scroll: a row title, `group:` + a group title, or nil for the top of the page.
    let anchor: String?
    /// Other words people might type for it.
    let terms: String

    var id: String { "\(tab.rawValue)/\(title)" }
    var location: String { [tab.label, group].compactMap { $0 }.joined(separator: " › ") }

    /// A row: found by its own title unless `named` gives it a clearer one.
    static func row(_ rowTitle: String, _ tab: SettingsTab, in group: String?, named: String? = nil, _ terms: String = "") -> Self {
        Self(title: named ?? rowTitle, tab: tab, group: group, anchor: rowTitle, terms: terms)
    }

    /// A whole group, for things that aren't a single titled row (a grid, a list).
    static func group(_ groupTitle: String, _ tab: SettingsTab, named: String, _ terms: String = "") -> Self {
        Self(title: named, tab: tab, group: groupTitle, anchor: "group:" + groupTitle, terms: terms)
    }

    /// The top of a page.
    static func page(_ tab: SettingsTab, named: String, _ terms: String = "") -> Self {
        Self(title: named, tab: tab, group: nil, anchor: nil, terms: terms)
    }
}

enum SettingsSearch {
    /// Every setting, page by page in sidebar order. Row titles here must match the rows' titles
    /// on the pages, or picking the result opens the page without scrolling to the row.
    static let entries: [SettingsSearchEntry] = [
        // General
        .group("Default browser", .general, named: "Default browser", "make default links other apps open"),
        .row("Reopen tabs", .general, in: "Startup & quitting", "restore session startup launch last windows"),
        .row("Ask before quitting", .general, in: "Startup & quitting", "confirm quit ⌘q command q close"),
        .row("Reduce animations", .general, in: "Motion", "motion animation springs fades accessibility"),

        // Import
        .group("Browser", .importData, named: "Import from another browser",
               "migrate switch move bookmarks history favourites pinned spaces safari chrome arc zen firefox edge brave dia vivaldi opera"),

        // Theme
        .group("Background", .appearance, named: "Background style", "glass vibrancy solid seamless window material"),
        .row("Transparency", .appearance, in: "Window", "opacity see-through translucent glass"),
        .row("Blur", .appearance, in: "Window", "glass frosted"),
        .row("Grain", .appearance, in: "Window", "noise texture"),
        .row("Sheen", .appearance, in: "Window", "shine gloss highlight"),
        .row("Seamless in Incognito windows", .appearance, in: "Window", "private page colour header"),
        .row("Each space has its own colour", .appearance, in: "Colour", "tint space"),
        .group("Colour", .appearance, named: "Tint colour", "accent window hue swatch"),
        .row("Sidebar text", .appearance, in: "Colour", "dark light mode appearance text contrast"),
        .row("Corner radius", .appearance, in: "Page", "rounded corners page card roundness"),
        .row("Border gap", .appearance, in: "Page", "inset margin padding page edge"),
        .row("Reset Theme", .appearance, in: nil, "default restore appearance"),

        // Layout
        .row("Main browsing", .layout, in: "Tabs", named: "Tab position", "vertical horizontal tabs sidebar top tab bar layout"),
        .row("Incognito", .layout, in: "Tabs", named: "Tab position in Incognito", "private vertical horizontal tabs layout"),
        .row("Show the bookmarks bar", .layout, in: "Bookmarks", named: "Bookmarks bar", "bookmarks bar favourites toolbar star saved pages"),
        .row("Width", .layout, in: "Sidebar", named: "Sidebar width", "size wide narrow"),
        .row("Show when the pointer reaches the edge", .layout, in: "Sidebar", named: "Show the hidden sidebar at the edge",
             "peek hover float sidebar auto hide"),
        .row("Always show close buttons", .layout, in: "Tab rows", "x tabs"),
        .row("Compact rows", .layout, in: "Tab rows", "dense smaller tabs density"),

        // Tabs
        .row("New tabs go at the", .tabs, in: "Opening", named: "New tab position", "new tabs top bottom order place"),
        .row("Switch to tabs opened with ⌘-click", .tabs, in: "Opening", "background foreground links command click focus"),
        .row("Open a New Tab page", .tabs, in: "Opening", "new tab page empty blank start command t logo"),
        .row("After closing a tab, show", .tabs, in: "Closing", "close select next previous"),
        .row("Close tabs I haven’t viewed in", .tabs, in: "Closing", named: "Close idle tabs automatically",
             "archive old idle auto close cleanup tidy"),
        .row("Picture in Picture when switching tabs", .tabs, in: "Video", "pip video floating player"),
        .row("Unload background tabs after", .tabs, in: "Memory", "memory sleep suspend discard performance ram"),

        // Spaces & Profiles
        .group("Spaces", .spaces, named: "Spaces", "workspace rename reorder icon colour delete add new"),
        .group("Profiles", .spaces, named: "Profiles", "cookies sign-ins accounts separate logins new"),

        // Search
        .row("Search engine", .search, in: nil, "google duckduckgo bing kagi ecosia default"),
        .row("Search engine", .search, in: nil, named: "Custom search engine", "custom url template %s"),
        .row("Search suggestions", .search, in: "Suggestions in the command bar", "autocomplete address bar"),
        .row("Pages from your history", .search, in: "Suggestions in the command bar", "history suggestions autocomplete"),
        .row("Open tabs", .search, in: "Suggestions in the command bar", named: "Suggest open tabs", "switch to tab"),
        .row("Bookmarks", .search, in: "Suggestions in the command bar", named: "Suggest bookmarks", "bookmark saved pages star"),
        // Bangs are listed once, under Mods where they're switched on and set up; the Search page
        // only links there.

        // Downloads
        .row("Save files to", .downloads, in: "Location", named: "Download folder", "location folder directory save"),
        .row("Ask where to save each file", .downloads, in: "Location", "prompt location"),
        .row("Show the downloads list when a download starts", .downloads, in: "During and after", "panel popup"),
        .row("Open safe files after downloading", .downloads, in: "During and after", "auto open pdf"),
        .row("Downloads list", .downloads, in: "This session", named: "Clear finished downloads", "clear list"),

        // Privacy & Security
        .row("Save browsing history", .privacy, in: "History", "history record"),
        .row("Clear history when Tuff quits", .privacy, in: "History", "delete erase quit"),
        .row("History", .privacy, in: "History", named: "Show or clear history", "clear delete erase view browsing history"),
        .row("Cookies and site data", .privacy, in: "Website data", named: "Cookies and website data",
             "clear remove delete sign out logins storage"),
        .row("Cache", .privacy, in: "Website data", named: "Empty cache", "clear cache storage"),
        .row("Block ads and trackers", .privacy, in: "Content blocking", "ad blocker adblock ublock tracking easylist filter lists"),
        .row("Upgrade to HTTPS", .privacy, in: "Security", "secure ssl tls https-first"),
        .row("Always use secure connections", .privacy, in: "Security", "https-only https-first secure ssl tls insecure http warning"),
        .row("Warn about fraudulent websites", .privacy, in: "Security", "phishing malware safe browsing fraud"),

        .row("When a language isn’t on this Mac", .privacy, in: "Translation", named: "Translation", "translate google translation language download"),

        // Passwords
        .row("Save and fill passwords", .passwords, in: nil, "passwords logins autofill sign in save offer"),
        .group("Saved passwords", .passwords, named: "Saved passwords", "passwords logins show copy edit delete add"),
        .row("Import passwords", .passwords, in: "Import and export", "csv import passwords chrome safari 1password bitwarden"),
        .row("Export passwords", .passwords, in: "Import and export", "csv export passwords backup"),

        // Websites
        .group("Site permissions", .websites, named: "Site permissions", "camera microphone location notifications allowed blocked forget"),
        .group("Sites", .websites, named: "Settings for each site",
               "site permissions camera microphone location notifications ask allow deny block reset per site"),
        .row("Remember my choice by default", .websites, in: "Site permissions", "permissions remember camera microphone"),
        .row("Block pop-ups", .websites, in: "Content", "popup popups windows new tabs"),
        .row("Allow JavaScript", .websites, in: "Content", "js scripts disable"),
        .row("Autoplay video and audio", .websites, in: "Content", "media sound video mute"),
        .row("Default zoom", .websites, in: "Zoom & text", "page zoom size scale bigger smaller"),
        .group("Zoom & text", .websites, named: "Zoom for each site", "per site zoom remembered reset"),
        .row("Never use font sizes smaller than", .websites, in: "Zoom & text", named: "Minimum font size",
             "text font size small readability"),

        // Extensions
        .group("Add extensions", .extensions, named: "Add extensions",
               "install chrome web store firefox add-ons load unpacked crx xpi"),
        .group("Installed", .extensions, named: "Installed extensions", "remove disable options update"),

        // Mods
        .row("DuckDuckGo Bangs", .mods, in: nil, "bangs ! !yt !w search shortcuts"),
        .row("Look up a bang", .mods, in: nil, "bangs search"),
        .row("Bang list", .mods, in: nil, named: "Update bang list", "bangs download"),

        // Shortcuts & Gestures
        .page(.shortcuts, named: "Keyboard shortcuts", "keys hotkeys keyboard"),
        .row("Swipe between pages", .shortcuts, in: "Gestures", "back forward trackpad two finger swipe navigation"),
        .row("Link previews", .shortcuts, in: "Gestures", "force click peek quick look trackpad"),
        .row("Switch spaces", .shortcuts, in: "Gestures", "swipe trackpad sidebar"),

        // Advanced
        .row("Web Inspector", .advanced, in: "Developer", "developer tools devtools inspect element console"),
        .row("Identify as", .advanced, in: "User agent", named: "User agent", "safari chrome firefox browser identify custom"),
        .row("Back up or move your settings", .advanced, in: "Backup & reset", named: "Export or import settings",
             "backup export import json file move"),
        .row("Reset all settings", .advanced, in: "Backup & reset", "defaults factory restore"),

        // About
        .row("Software update", .about, in: nil, named: "Check for updates", "version update about upgrade new release"),
        .row("Channel", .about, in: nil, named: "Update channel", "nightly stable releases builds"),
        .row("Check automatically", .about, in: nil, named: "Check for updates automatically", "update daily background"),
    ]

    /// Lower-cased, with one spelling of words written two ways, so "color" finds "colour".
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "colour", with: "color")
            .replacingOccurrences(of: "favourite", with: "favorite")
    }

    static func words(_ query: String) -> [String] {
        normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Settings matching every word of the query, best first: titles that start with the query,
    /// then titles that contain every word, then the rest.
    static func results(for query: String) -> [SettingsSearchEntry] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        let whole = normalize(query.trimmed)
        let scored: [(entry: SettingsSearchEntry, score: Int, index: Int)] = entries.enumerated().compactMap { index, entry in
            let title = normalize(entry.title)
            let haystack = [title, normalize(entry.group ?? ""), normalize(entry.terms)].joined(separator: " ")
            guard words.allSatisfy(haystack.contains) else { return nil }
            let score = title.hasPrefix(whole) ? 0 : (words.allSatisfy(title.contains) ? 1 : 2)
            return (entry, score, index)
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.entry)
    }

    /// Where Return in the search field goes: a page the query names, otherwise the best setting,
    /// otherwise a page that matched on one of its other names.
    static func best(for query: String) -> (tab: SettingsTab, anchor: String?)? {
        let pages = pages(for: query)
        let whole = normalize(query.trimmed)
        if let named = pages.first(where: { normalize($0.label).contains(whole) }) { return (named, nil) }
        if let entry = results(for: query).first { return (entry.tab, entry.anchor) }
        return pages.first.map { ($0, nil) }
    }

    /// Pages whose name (or a few synonyms) match every word of the query.
    static func pages(for query: String) -> [SettingsTab] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        return SettingsTab.allCases.filter { tab in
            let haystack = normalize(tab.label + " " + tab.keywords)
            return words.allSatisfy(haystack.contains)
        }
    }
}

// MARK: - Result row

/// A setting in the sidebar's search results: its name, and the page and group it lives in.
struct SettingsResultRow: View {
    let entry: SettingsSearchEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: entry.tab.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.45))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(2)
                    Text(entry.location)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Links between pages

/// A small button that takes you to another page of Settings (and, optionally, a setting on it).
struct SettingsLink: View {
    let title: String
    let tab: SettingsTab
    var anchor: String?
    @Environment(SettingsRouter.self) private var router: SettingsRouter?

    var body: some View {
        Button {
            router?.go(tab, anchor: anchor)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
        }
        .buttonStyle(TuffButtonStyle())
    }
}
