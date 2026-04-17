#  Project Context

## Overview

- iOS 26 SwiftUI app targeting iPhone and iPad
- Minimum deployment: iOS 26
- Swift 7 with strict concurrency
- Uses SwiftUI throughout - no UIKit unless absolutely necessary

## Native-First Implementation (Required)

- Always prefer Apple native APIs, controls, and behaviors over custom implementations.
- If a native SwiftUI/UIKit solution exists for a feature, use it.
- Do not implement custom gesture/drag/drop/reordering/selection logic when Apple provides built-in equivalents.
- For list reordering, use `List` + `.onMove` (or equivalent native edit actions), not custom `onDrag`/`onDrop`.
- For navigation, presentation, search, refresh, menus, focus, swipe actions, and editing, use Apple-provided modifiers/components first.
- Only use custom logic when native APIs cannot meet the requirement.
- If custom logic is necessary, explicitly explain why native APIs were insufficient before implementing.

## Architecture

- MVVM with @OBservable ViewModels (NOT observableObjects)
- Views on their ViewModel as a @State property
- ViewModels handle all business logic - Views are declaritive only
- Navigation uses NavigationStack with NavigationPath - never NavigationView
- Dependency injection through the SwiftUI Enviroment
- use AppStorage for simple user prefernces
- use SwiftData for persistent models

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

## Plex Audio Streaming
- ALWAYS use the universal transcode HLS endpoint (`/music/:/transcode/universal/start.m3u8`) for audio playback
- NEVER direct-stream raw audio files via the part key URL — AVPlayer cannot reliably track time, seek, or report duration on raw FLAC/WAV over HTTP
- Use `directStreamAudio=1` so Plex wraps the original audio in a proper HLS container without re-encoding
- `AVPlayerItem(url:)` works directly with HLS URLs — no custom HTTP headers needed
- If audio playback issues arise, check the stream URL first before adding complexity to AudioPlayerService

## Code Style
- All new views must include a #Preview Block
- Use SF symbols for icons - reference by exact name
- Prefer Liquid Glass materials for iOS 26 UI
- File organization: one type per file
- Naming: PascalCase for types, cameCase for properties
- Group files by feature, not by type (Weather/, Profile/, Settings/)

## Logging & Diagnostics
- All verbose diagnostics and development logs must be gated to debug builds only (`#if DEBUG`).
- Release builds must not emit internal debug traces to the console.
- If runtime toggles are used for diagnostics, they must only be honored in debug builds.
