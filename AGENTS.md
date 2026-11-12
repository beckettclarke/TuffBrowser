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

## Build and test

- `make build` regenerates the Xcode project from `project.yml` (XcodeGen) and builds Debug.
- `make run` builds and launches.
- Debug builds can be scripted with `TUFF_DEBUG_SCRIPT` (see `TuffBrowser/Support/DebugHooks.swift`),
  e.g. `snap` / `snapall` for screenshots and `prompt yes|no` to answer an on-screen card.
