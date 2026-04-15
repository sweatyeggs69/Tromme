# Tromme Performance Baseline

Last updated: 2026-04-16

## Current Baseline

- Scenario: Open each main tab, scroll to bottom, scroll back to top.
- Memory after pass: ~123 MB.
- Fast scroll behavior: artwork loads quickly; occasional split-second delay on instant jump-to-top in Albums.
- Image cache stats (debug run):
  - lookups: 568
  - memory hits: 119 (21.0%)
  - disk hits: 449 (79.0%)
  - misses: 0 (0.0%)
  - network requests: 0
  - average lookup latency: 2.8 ms

## Targets

- Post-navigation memory target: < 175 MB on iPhone.
- No multi-second artwork blank states during normal scrolling.
- Jump-to-top should keep delays brief (sub-second).

## How to Measure

1. Launch app from Xcode in Debug.
2. Authenticate and open a music library.
3. Visit Home, Artists, Albums, Songs, Search.
4. In Artists and Albums, perform a long fast scroll down and back up.
5. Record memory from Xcode debug gauge after UI settles.
6. Note any visible artwork loading delays.

## Regression Signals

- Memory rises above ~200 MB in the same scenario.
- Artwork appears as placeholders for multiple seconds during normal list/grid scrolling.
- Noticeable hitching introduced after image/cache changes.
