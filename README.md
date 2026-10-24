# Pane

A native macOS browser built on Chromium (CEF) with a Liquid Glass interface, vertical tabs and workspaces, a built-in AI assistant/agent, and sync.

> Нативный браузер для macOS на Chromium: стеклянный интерфейс, вертикальные вкладки, рабочие пространства, ИИ-ассистент и агент, синхронизация. Интерфейс на русском и английском.

## Features

- **Interface:** Liquid Glass, vertical tabs, groups, pinned tabs, workspaces, split view, tab sleeping, colour themes, site-colour sidebar tint
- **Search:** ⌘K palette over tabs, bookmarks and history (keywords and meaning; Russian word forms)
- **Assistant & agent:** ask about pages, or let the agent browse for you (open/close tabs, fill forms, organise bookmarks, watch pages, research, job applications). Bring your own key (Anthropic, OpenAI or compatible); the key lives in the macOS Keychain. The agent never types passwords or card numbers and confirms risky steps.
- **Reading:** reader mode, page summary, page translation, native PDF viewer, picture in picture
- **Privacy:** ad and tracker blocking, private windows, profiles, saved logins in the Keychain (optionally synced end-to-end encrypted)
- **Library:** bookmarks (import from Chrome, Safari, Arc), history and downloads window
- **Accounts & sync:** bookmarks, preferences and encrypted logins across Macs (own server in `server/`)
- **Updates:** in-app updater with release notes; crash reports are sent only if you agree

## Layout

| Module | Purpose |
|---|---|
| `CEFBridge` | Objective-C++ bridge to Chromium Embedded Framework |
| `PaneEngine` | Engine-agnostic protocols (UI never touches CEF directly) |
| `PaneCEF` | CEF implementation of those protocols |
| `PaneModel` | Pure models: tabs, bookmarks, settings, workspaces, agent loop… |
| `PaneUI` | AppKit + SwiftUI interface |
| `PaneAssistant` | LLM providers (Anthropic, OpenAI-compatible) |
| `PaneSync`, `PaneUpdate`, `PaneSearch`, `PaneImport` | Sync client, updater, search, importers |
| `Pane` | App entry point and menus |
| `server/` | Node.js sync / crash-report server |

Layers (engine / UI / assistant) don't depend on each other directly.

## Build

Requires macOS 26+ and Xcode with Swift 6.

```bash
scripts/fetch_cef.sh     # downloads the pinned CEF build into third_party/ (~480 MB)
scripts/build.sh         # builds build/Pane.app (signs with an Apple Development identity if you have one, otherwise ad-hoc)
swift test               # unit tests
```

Strings: Russian translations live in `scripts/strings_ru.py` (+ `strings_ru_extra.py`); `scripts/strings_ru.py check` lists untranslated keys.

## Release & server (maintainers)

`scripts/release.sh "notes"` builds, zips, writes the update feed and uploads it (see `scripts/publish.sh` — it targets the author's own server; change the host and key there). The sync server in `server/` runs with `docker compose up -d`.

## Test aids

The app has many `PANE_DEBUG_*` environment switches (offscreen snapshots, stress runs, feature probes) used by the author's test runs; see `Sources/Pane/main.swift`.
