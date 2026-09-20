#  Project Context

## Overview

- iOS 27 SwiftUI app targeting iPhone and iPad
- Minimum deployment: iOS 27
- SwiftUI is preferred, use UIKit as fallback
- All UI must follow iOS 27 design language and Liquid Glass styling
- Always use lean changelogs when pushing commits

## STRICT RULE: Always Use Stock Apple First

Before implementing ANY feature, control, layout, or behavior:
1. Check if Apple provides a stock/default/built-in way to do it in iOS 27
2. If Apple provides it, use it — no custom implementations
3. Only build custom when Apple has NO equivalent

This applies to everything:
- Navigation: use NavigationStack, TabView, Tab(role:) — never custom tab bars or navigation
- Tab bars: let the system render Liquid Glass — never apply custom materials or shapes to tab bars
- Toolbars: use .toolbar with proper ToolbarItem placements — never custom floating bars
- Mini players / accessories: use .toolbar(placement: .bottomBar) or .safeAreaInset — never custom overlays
- Search: use Tab(role: .search) or .searchable — never custom search buttons
- Sheets/covers: use .sheet, .fullScreenCover with system presentation — never custom modals
- Lists: use List with native swipe actions, .onMove, .onDelete — never custom gesture handlers
- Progress: use native ProgressView, Slider, Gauge — never custom drawn progress bars
- Volume: use MPVolumeView — never fake volume sliders
- AirPlay: use AVRoutePickerView — never fake AirPlay buttons
- Materials: let the system apply Liquid Glass — only use .glassEffect when the system doesn't provide it automatically
- Alerts/confirmations: use .alert, .confirmationDialog — never custom alert views
- Pull to refresh: use .refreshable — never custom pull indicators
- Scroll indicators, safe areas, keyboard avoidance: use system defaults

If you are unsure whether Apple provides something, assume they do and look for it before writing custom code.

## Architecture

- MVVM with @Observable ViewModels (NOT ObservableObject)
- Views own their ViewModel as a @State property
- ViewModels handle all business logic - Views are declarative only
- Navigation uses NavigationStack with NavigationPath - never NavigationView
- Dependency injection through the SwiftUI Environment
- use AppStorage for simple scalar user preferences
- use SwiftData for persistent models
- use disk files (Codable → JSON) for complex persistent state (e.g. playback queue); never NSUserDefaults for structured data
- Toggles and buttons with different states should always transform unless otherwise stated.

## Build System
- use BuildProject for completion (not shell commands or xcodebuild)
- Previews are available via RenderPreview
- SPM for package management - no CocoaPods
- Build target: "MyApp" iOS

## Testing
- Use Swift Testing framework -- NOT XCTest
- Test functions use @Test attribute, not func textXYZ()
- Use #expect() for assertions - not XCTAssertEqual
- Test target: CLAUDEmdTests
- Run with RunAllTests or RunSomeTests MCP tools

## Documentation & APIs
- Use DocumentationSearch for Apple API questions
- Do NOT hallucinate API names - Verify with the docs first
- prefer async/await - never completion handlers
- use structured concurrency (TaskGroup) over manual task management
- Error handling: use typed throws where supported

## iOS 27 / Liquid Glass Requirements
- Tab bars, toolbars, and navigation bars get Liquid Glass automatically — do not manually apply .glassEffect to them
- Use Tab(role: .search) for search — never a custom search button or separate tab
- Navigation must use the iOS 27 tab bar style (floating Liquid Glass pill)
- Sheets, popovers, and alerts should use system presentation styles
- Prefer .contentTransition(.symbolEffect) for animated icon changes
- All designs should look and feel like a stock iOS 27 app
- Only use .glassEffect on custom views that need glass treatment and aren't already system-managed

## Popups & Confirmation UX
- Confirmation flows must use alert-style popups (`.alert`) instead of confirmation sheets (`.confirmationDialog`).
- Use destructive alert actions for destructive operations (delete, sign out, clear cache), with an explicit cancel action.

## STRICT RULE: Plex API Must Match the Documented Architecture 1:1

`/Users/kylemcclain/Tromme/plex-api.json` (repo root) is the source of truth for all Plex Media Server integration. No matter what:
1. Before adding or changing any PMS request, look up the exact endpoint, path, and query/header parameter names in `plex-api.json` first.
2. Only call endpoints that exist in that spec, with only the parameter names it documents. Never invent, guess, or carry over an undocumented endpoint/param just because another Plex client (or old Tromme code) used it.
3. Use the purpose-built endpoint family for the task at hand instead of repurposing a different one — e.g. offline downloads go through the `/downloadQueue` family (`Download Queue` tag), not the streaming `/{transcodeType}/:/transcode/universal/*` endpoints used for playback.
4. If a desired behavior has no documented endpoint, treat that as a sign to re-check the spec or ask for the correct one — don't fall back to an undocumented path "because it happens to work."

## Plex Audio Streaming
- FLAC files use the universal transcode endpoint to convert FLAC→ALAC (Apple Lossless) via HLS
  - ALAC is lossless — identical decoded audio to FLAC — with proper AVPlayer seeking/timeline
  - Flow: decision endpoint → master playlist → resolve variant playlist URL → play variant directly
  - Bypassing the master playlist avoids HLS BANDWIDTH mismatch that stalls AVPlayer
  - Profile: `add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=alac)`
  - Key params: `directPlay=0`, `directStreamAudio=0`, `X-Plex-Client-Profile-Name: Generic`
- Non-FLAC formats use direct stream via part key URL
- NEVER direct-stream raw FLAC files — AVPlayer audio drifts out of sync over time due to FLAC's variable bitrate
- HLS+MPEGTS cannot carry FLAC (Apple only supports AAC/MP3/AC3 in MPEGTS)
- Always send `X-Plex-Client-Profile-Extra` header — without it PMS returns 400 ("client provided bad data")

## Plex Offline Downloads
- MP3 (space-saver) downloads use the documented Download Queue API — never the streaming universal-transcode endpoint:
  - POST `/downloadQueue` → get-or-create this client's queue (idempotent per client id + token)
  - POST `/downloadQueue/{queueId}/add` with `keys`, `protocol=http`, `directPlay=0`, `directStream=0`, `directStreamAudio=0`, `musicBitrate`, plus `X-Plex-Client-Profile-Extra: add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=mp3&audioCodec=mp3&replace=true)`
  - Poll GET `/downloadQueue/{queueId}/items/{itemId}` until status is `available` (or fail on `error`/`expired`)
  - GET `/downloadQueue/{queueId}/item/{itemId}/media` (singular "item") to fetch the finished file
  - DELETE `/downloadQueue/{queueId}/items/{itemId}` (plural "items") afterward for cleanup
- Original-quality downloads use the documented direct part endpoint instead: `/library/parts/{partId}/{changestamp}/{filename}?download=1` — this is its own documented endpoint, not part of the Download Queue family, so don't route it through the queue.

## Code Style
- All new views must include a #Preview Block
- Use SF symbols for icons - reference by exact name
- File organization: one type per file
- Naming: PascalCase for types, camelCase for properties
- Group files by feature, not by type (Weather/, Profile/, Settings/)

## Color Contrast (black/white foreground on a colored background)
- Use the shared `Color.isLightColor(in:)` helper in `Core/Styling/AppStyle.swift` — never re-implement luminance/contrast math per-view.
- It returns `true` when the background is light enough that black content reads better; pick `.black` when `true`, `.white` when `false`.
- Pass `colorScheme` (from `@Environment(\.colorScheme)`) when the background color is dynamic (e.g. `Color(.label)`, or anything from an environment/icon-pack accent color) so it resolves to concrete RGB first. Pass `nil` for fixed colors that don't vary with appearance (e.g. artwork-sampled colors from `ArtworkColorCache`).
- Used today by `AlbumDetailView`, `PlaylistDetailView` (artwork-driven controls), and `ArtistDetailView` (accent-color-driven shuffle button).

## Logging & Diagnostics
- All verbose diagnostics and development logs must be gated to debug builds only (`#if DEBUG`).
- Release builds must not emit internal debug traces to the console.
- If runtime toggles are used for diagnostics, they must only be honored in debug builds.
