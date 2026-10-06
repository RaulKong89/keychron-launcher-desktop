# Lyricalizer LRCLIB — iOS 5/6

Community rebuild of the classic Lyricalizer behavior for legacy iOS.

- Targets rootful armv7 (iPhone 4S / iOS 6.1.3 included).
- Uses the current LRCLIB API directly.
- Exact lookup uses title + artist + album + duration, then relaxes the query.
- Falls back to LRCLIB search and picks the closest metadata match.
- Prefers plain lyrics; converts synced LRC to plain text when needed.
- Keeps embedded lyrics untouched.
- Caches fetched lyrics at:
  /var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.cache.plist
- No API key required.

## Use

Install the .deb, respring (or kill/relaunch Music), play a track, then tap the album artwork.
The tweak begins fetching as soon as the Now Playing content is prepared. If the first tap happens before the network request finishes, the stock lyrics sheet shows a short downloading message; tap the artwork again after a moment.

## Network note

LRCLIB is HTTPS-only. iOS 6 must have working modern HTTPS/TLS/root certificates. If the device can already open modern HTTPS sites through its legacy TLS fixes, no additional server is needed.

## Credits / license

Original Lyricalizer by ac3xx / James Long.
Original source: https://github.com/ac3xx/Lyricalizer
This port is non-commercial and keeps attribution to the original project.
LRCLIB: https://lrclib.net/
