# IntroDB / TheIntroDB Integration — Skip Intros & Credits

## Overview

Two community-powered databases provide timestamps for TV show intros, credits, recaps, and previews. Forge can use these to automatically mark or skip segments during playback on the Forge TV companion app, or to apply different encoding parameters to intro/credits sections.

## Services

### IntroDB (introdb.app)
- **API**: `https://api.introdb.app`
- **Auth**: None (anonymous, unauthenticated)
- **Query**: By IMDB ID
- **Data**: Intro start/end timestamps only
- **Coverage**: ~8,500 shows
- **Response time**: <50ms globally

```
GET https://api.introdb.app/intro?imdb=tt0944947
→ { "start": 2.5, "end": 58.0 }
```

### TheIntroDB / TIDB (theintrodb.org)
- **API**: `https://api.theintrodb.org`
- **Auth**: API key (free registration)
- **Query**: By TMDB ID, IMDB ID, or TVDB ID
- **Data**: Intro, recap, credits, preview segments
- **Coverage**: ~49,000 shows (5× more than IntroDB)
- **Integrations**: Jellyfin, Emby, Stremio, browser extensions

```
GET https://api.theintrodb.org/get_intros?tmdb_id=1399
→ [{ "type": "intro", "start": 2.5, "end": 58.0, "season": 1, "episode": 1 }]
```

## Integration Points in Forge

### 1. MediaLibrary Metadata (Phase 3 — ForgeServer)

When a media item is cataloged and TMDb metadata is fetched, simultaneously query IntroDB/TIDB for skip timestamps. Store in the `MediaItem` SwiftData model:

```swift
// Addition to MediaItem model
var introStart: Double?      // Seconds
var introEnd: Double?
var creditsStart: Double?
var creditsEnd: Double?
var recapStart: Double?
var recapEnd: Double?
```

### 2. Forge TV Playback (Phase 3 — Forge TV)

During AVPlayer playback, use boundary time observers to show "Skip Intro" / "Skip Credits" buttons:

```swift
let times = [NSValue(time: CMTimeMakeWithSeconds(introStart, preferredTimescale: 600))]
player.addBoundaryTimeObserver(forTimes: times, queue: .main) {
    showSkipButton()
}
```

### 3. Encoding Optimization (ForgeOptimizer Integration)

Intro/credits segments are typically:
- **Intros**: Same every episode → highly compressible with aggressive QP
- **Credits**: Simple text on black/gradient → very low complexity

ForgeOptimizer can use segment timestamps to apply different encoding parameters:

```swift
// In the analysis pass, if we know this is an intro segment:
if currentTime >= introStart && currentTime <= introEnd {
    encodingHints.bitrateMultiplier = 0.5  // Compress intro more aggressively
    encodingHints.useLongGOP = true         // Longer GOPs for repetitive content
}
```

### 4. ForgeServer API (Phase 3)

Expose skip segment data to Forge TV via the REST API:

```
GET /api/v1/media/{id}/segments
→ {
    "intro": { "start": 2.5, "end": 58.0 },
    "credits": { "start": 1245.0, "end": 1320.0 },
    "recap": null,
    "preview": null
  }
```

## Implementation Plan

### Phase 1: Lightweight Client (add to ForgeKit shared package)

```swift
/// Queries IntroDB and TheIntroDB for skip segment timestamps.
public actor SkipSegmentClient {

    /// Fetch intro/credits timestamps for a TV episode.
    /// Tries TheIntroDB first (more data), falls back to IntroDB.
    public func fetchSegments(
        tmdbId: Int?,
        imdbId: String?,
        season: Int?,
        episode: Int?
    ) async throws -> SkipSegments

    /// Cached results to avoid re-fetching during playback.
    private var cache: [String: SkipSegments] = [:]
}

public struct SkipSegments: Codable, Sendable {
    public var intro: TimeRange?
    public var credits: TimeRange?
    public var recap: TimeRange?
    public var preview: TimeRange?
}

public struct TimeRange: Codable, Sendable {
    public var start: Double  // Seconds
    public var end: Double
}
```

### Phase 2: MediaLibrary Integration

- Fetch segments during TMDb metadata enrichment
- Store in `MediaItem` SwiftData model
- Expose via ForgeServer REST API

### Phase 3: Forge TV Skip Buttons

- AVPlayer boundary time observers
- "Skip Intro" overlay button (auto-dismiss after 10s)
- "Skip Credits" + "Next Episode" at credits start
- Siri Remote: press to skip, or wait to dismiss

### Phase 4: Encoding Optimization

- Use segment timestamps in ForgeOptimizer analysis pass
- Lower bitrate for known intro/credits regions
- Potentially skip encoding credits entirely for signage use case

## Sources

- [IntroDB](https://introdb.app/) — anonymous intro timestamp API
- [TheIntroDB](https://theintrodb.org/docs) — comprehensive segment database with TMDB lookup
- [Firecore community discussion](https://community.firecore.com/t/support-for-theintrodb-api-for-skip-intro-outro-management/58939) — integration patterns
- [TheIntroDB Jellyfin plugin](https://github.com/TheIntroDB/jellyfin-plugin) — reference implementation
