#  Project Context

## Overview

- iOS 26 SwiftUI app targeting iPhone and iPad
- Minimum deployment: iOS 26
- Swift 6 with strict concurrency
- Uses SwiftUI throughout - no UIKit unless absolutely necessary
- All UI must follow iOS 26 design language and Liquid Glass styling

## STRICT RULE: Always Use Stock Apple First

Before implementing ANY feature, control, layout, or behavior:
1. Check if Apple provides a stock/default/built-in way to do it in iOS 26
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
- use AppStorage for simple user preferences
- use SwiftData for persistent models
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

## iOS 26 / Liquid Glass Requirements
- Tab bars, toolbars, and navigation bars get Liquid Glass automatically — do not manually apply .glassEffect to them
- Use Tab(role: .search) for search — never a custom search button or separate tab
- Navigation must use the iOS 26 tab bar style (floating Liquid Glass pill)
- Sheets, popovers, and alerts should use system presentation styles
- Prefer .contentTransition(.symbolEffect) for animated icon changes
- All designs should look and feel like a stock iOS 26 app
- Only use .glassEffect on custom views that need glass treatment and aren't already system-managed

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

## Code Style
- All new views must include a #Preview Block
- Use SF symbols for icons - reference by exact name
- File organization: one type per file
- Naming: PascalCase for types, camelCase for properties
- Group files by feature, not by type (Weather/, Profile/, Settings/)
