# Lyricalizer LRCLIB v4 — iOS 6 / armv7

A modern, self-contained community rebuild of the classic Lyricalizer behavior for the iOS 6 Music app.

## Behavior

- Preserves embedded lyrics already present in the media file.
- Silently prefetches missing lyrics when a track becomes Now Playing.
- Tapping artwork only opens the classic MusicLyricsView when real lyrics exist.
- There is **no** "Downloading...", "Searching...", "No lyrics found", or empty lyric overlay.
- If all sources confirm no lyrics, the normal album artwork remains untouched.
- Confirmed misses are cached for 12 hours, then retried because community databases can gain lyrics later.
- Successful lyrics are cached locally for offline use.

## Search order

1. LRCLIB exact signature: title + artist + album + duration.
2. LRCLIB exact title + artist without edition-specific album/duration.
3. LRCLIB structured search.
4. LRCLIB free-text search.
5. lyrics.ovh — a community multi-source aggregator.
6. Public LrcAPI advanced search as a last resort, accepted only when title and artist safely match.

Requests are sequential, LRCLIB calls are throttled, and HTTP 429/503 Retry-After is honored.

## Networking

The package includes its own armv7 mbedTLS TLS 1.2 client and current CA bundle. It does not require TLSFix or a separately installed certificate profile for lyric requests.

## Compatibility

- Rootful jailbreak
- armv7
- iOS 6 target / iOS 6.1 SDK build
- MobileSubstrate
- Stock Music.app / MusicLyricsView behavior

## Cache files

- Positive lyrics: `/var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.cache.plist`
- Confirmed misses: `/var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.miss.plist`

Experimental placeholder/error strings from earlier builds are purged automatically on first launch.

## Credits

Original Lyricalizer by ac3xx / James Long.
LRCLIB community, lyrics.ovh community, LrcAPI community.
