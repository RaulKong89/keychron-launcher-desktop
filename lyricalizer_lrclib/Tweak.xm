#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

@interface MPAVItem : NSObject
- (NSString *)lyrics;
- (NSString *)mainTitle;
- (NSString *)artist;
- (NSString *)albumArtist;
- (NSString *)album;
- (double)durationInSeconds;
- (unsigned long long)persistentID;
@end

@interface MusicNowPlayingViewController : UIViewController
- (id)_createContentViewForItem:(id)item contentViewController:(id *)contentViewController;
@end

static NSString * const LYCachePath = @"/var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.cache.plist";
static NSString * const LYUserAgent = @"Lyricalizer-LRCLIB/1.0 (iOS 6 jailbreak community port; https://github.com/ac3xx/Lyricalizer)";

static NSMutableDictionary *LYCache = nil;
static NSMutableSet *LYInflight = nil;
static dispatch_queue_t LYQueue = NULL;

static void LYInitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:LYCachePath];
        LYCache = saved ? [saved mutableCopy] : [[NSMutableDictionary alloc] init];
        LYInflight = [[NSMutableSet alloc] init];
        LYQueue = dispatch_queue_create("com.ac3xx.lyricalizer.lrclib.fetch", DISPATCH_QUEUE_SERIAL);
    });
}

static BOOL LYHasText(id value) {
    return value && value != [NSNull null] && [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0;
}

static NSString *LYSafeString(id value) {
    return LYHasText(value) ? (NSString *)value : @"";
}

static NSString *LYEncode(NSString *value) {
    if (!value) return @"";
    return [value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

static NSString *LYCacheKey(NSString *title, NSString *artist, NSString *album, unsigned long long persistentID) {
    if (persistentID != 0ULL) {
        return [NSString stringWithFormat:@"pid:%llu", persistentID];
    }
    return [NSString stringWithFormat:@"meta:%@|%@|%@",
            [LYSafeString(title) lowercaseString],
            [LYSafeString(artist) lowercaseString],
            [LYSafeString(album) lowercaseString]];
}

static void LYSaveCache(void) {
    NSDictionary *snapshot = nil;
    @synchronized(LYCache) {
        snapshot = [[NSDictionary alloc] initWithDictionary:LYCache];
    }
    [snapshot writeToFile:LYCachePath atomically:YES];
    [snapshot release];
}

static NSString *LYCachedLyricsForKey(NSString *key) {
    if (!key) return nil;
    LYInitState();
    @synchronized(LYCache) {
        id value = [LYCache objectForKey:key];
        return LYHasText(value) ? [[value retain] autorelease] : nil;
    }
}

static NSDictionary *LYJSONObjectForURL(NSString *urlString, NSInteger *statusCode) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:15.0];
    [request setValue:LYUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:LYUserAgent forHTTPHeaderField:@"Lrclib-Client"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSHTTPURLResponse *response = nil;
    NSError *networkError = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&networkError];

    if (statusCode) *statusCode = response ? [response statusCode] : 0;
    if (!data || networkError) {
        NSLog(@"[Lyricalizer LRCLIB] request failed: %@", networkError);
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return (NSDictionary *)object;
}

static id LYJSONAnyForURL(NSString *urlString, NSInteger *statusCode) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:15.0];
    [request setValue:LYUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:LYUserAgent forHTTPHeaderField:@"Lrclib-Client"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSHTTPURLResponse *response = nil;
    NSError *networkError = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&networkError];

    if (statusCode) *statusCode = response ? [response statusCode] : 0;
    if (!data || networkError) {
        NSLog(@"[Lyricalizer LRCLIB] request failed: %@", networkError);
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    return jsonError ? nil : object;
}

static NSString *LYPlainFromSynced(NSString *synced) {
    if (!LYHasText(synced)) return nil;

    NSArray *lines = [synced componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *plainLines = [NSMutableArray arrayWithCapacity:[lines count]];

    for (NSString *line in lines) {
        NSString *out = line;
        if ([out hasPrefix:@"["]) {
            NSRange close = [out rangeOfString:@"]"];
            if (close.location != NSNotFound && close.location + 1 < [out length]) {
                out = [out substringFromIndex:close.location + 1];
                if ([out hasPrefix:@" "]) out = [out substringFromIndex:1];
            } else if (close.location != NSNotFound) {
                out = @"";
            }
        }
        [plainLines addObject:out ?: @""];
    }

    NSString *result = [plainLines componentsJoinedByString:@"\n"];
    return [result length] ? result : nil;
}

static NSString *LYLyricsFromRecord(NSDictionary *record) {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;

    id instrumental = [record objectForKey:@"instrumental"];
    if ([instrumental respondsToSelector:@selector(boolValue)] && [instrumental boolValue]) {
        return @"Instrumental track — no lyrics.";
    }

    NSString *plain = [record objectForKey:@"plainLyrics"];
    if (LYHasText(plain)) return plain;

    NSString *synced = [record objectForKey:@"syncedLyrics"];
    if (LYHasText(synced)) return LYPlainFromSynced(synced);

    return nil;
}

static NSInteger LYScoreRecord(NSDictionary *record,
                               NSString *title,
                               NSString *artist,
                               NSString *album,
                               double duration) {
    NSInteger score = 0;
    NSString *rTitle = LYSafeString([record objectForKey:@"trackName"]);
    NSString *rArtist = LYSafeString([record objectForKey:@"artistName"]);
    NSString *rAlbum = LYSafeString([record objectForKey:@"albumName"]);

    if ([rTitle caseInsensitiveCompare:LYSafeString(title)] == NSOrderedSame) score += 100;
    else if ([[rTitle lowercaseString] rangeOfString:[LYSafeString(title) lowercaseString]].location != NSNotFound) score += 35;

    if ([rArtist caseInsensitiveCompare:LYSafeString(artist)] == NSOrderedSame) score += 80;
    else if ([[rArtist lowercaseString] rangeOfString:[LYSafeString(artist) lowercaseString]].location != NSNotFound) score += 25;

    if ([album length] && [rAlbum caseInsensitiveCompare:album] == NSOrderedSame) score += 20;

    id d = [record objectForKey:@"duration"];
    if (duration > 0.0 && [d respondsToSelector:@selector(doubleValue)]) {
        double delta = fabs([d doubleValue] - duration);
        if (delta <= 2.0) score += 40;
        else if (delta <= 5.0) score += 20;
        else if (delta <= 10.0) score += 5;
    }

    if (LYLyricsFromRecord(record)) score += 10;
    return score;
}

static NSString *LYFetchLyrics(NSString *title, NSString *artist, NSString *album, double duration) {
    if (![title length] || ![artist length]) return nil;

    NSMutableString *exact = [NSMutableString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@&artist_name=%@",
        LYEncode(title), LYEncode(artist)];

    if ([album length]) {
        [exact appendFormat:@"&album_name=%@", LYEncode(album)];
    }
    if (duration >= 1.0 && duration <= 3600.0) {
        [exact appendFormat:@"&duration=%.0f", duration];
    }

    NSInteger status = 0;
    NSDictionary *record = LYJSONObjectForURL(exact, &status);
    NSString *lyrics = LYLyricsFromRecord(record);
    if (lyrics) return lyrics;

    // Exact lookup can be intentionally strict about duration/album. Retry with
    // only title + artist before doing a fuzzy search.
    NSString *simple = [NSString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@&artist_name=%@",
        LYEncode(title), LYEncode(artist)];

    record = LYJSONObjectForURL(simple, &status);
    lyrics = LYLyricsFromRecord(record);
    if (lyrics) return lyrics;

    NSString *search = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?track_name=%@&artist_name=%@",
        LYEncode(title), LYEncode(artist)];

    id result = LYJSONAnyForURL(search, &status);
    if (![result isKindOfClass:[NSArray class]]) return nil;

    NSDictionary *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id candidate in (NSArray *)result) {
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        NSInteger score = LYScoreRecord(candidate, title, artist, album, duration);
        if (!best || score > bestScore) {
            best = candidate;
            bestScore = score;
        }
    }

    return LYLyricsFromRecord(best);
}

static void LYMetadataForItem(MPAVItem *item,
                              NSString **title,
                              NSString **artist,
                              NSString **album,
                              double *duration,
                              unsigned long long *persistentID) {
    NSString *t = @"";
    NSString *ar = @"";
    NSString *al = @"";
    double du = 0.0;
    unsigned long long pid = 0ULL;

    if ([item respondsToSelector:@selector(mainTitle)]) t = LYSafeString([item mainTitle]);
    if ([item respondsToSelector:@selector(artist)]) ar = LYSafeString([item artist]);
    if (![ar length] && [item respondsToSelector:@selector(albumArtist)]) ar = LYSafeString([item albumArtist]);
    if ([item respondsToSelector:@selector(album)]) al = LYSafeString([item album]);
    if ([item respondsToSelector:@selector(durationInSeconds)]) du = [item durationInSeconds];
    if ([item respondsToSelector:@selector(persistentID)]) pid = [item persistentID];

    if (title) *title = t;
    if (artist) *artist = ar;
    if (album) *album = al;
    if (duration) *duration = du;
    if (persistentID) *persistentID = pid;
}

static NSString *LYCachedLyricsForItem(MPAVItem *item) {
    NSString *title = nil, *artist = nil, *album = nil;
    double duration = 0.0;
    unsigned long long pid = 0ULL;
    LYMetadataForItem(item, &title, &artist, &album, &duration, &pid);
    return LYCachedLyricsForKey(LYCacheKey(title, artist, album, pid));
}

static void LYEnsureFetchForItem(MPAVItem *item) {
    if (!item) return;
    LYInitState();

    NSString *title = nil, *artist = nil, *album = nil;
    double duration = 0.0;
    unsigned long long pid = 0ULL;
    LYMetadataForItem(item, &title, &artist, &album, &duration, &pid);

    if (![title length] || ![artist length]) return;

    NSString *key = LYCacheKey(title, artist, album, pid);
    if (LYCachedLyricsForKey(key)) return;

    @synchronized(LYInflight) {
        if ([LYInflight containsObject:key]) return;
        [LYInflight addObject:key];
    }

    NSString *titleCopy = [title copy];
    NSString *artistCopy = [artist copy];
    NSString *albumCopy = [album copy];
    NSString *keyCopy = [key copy];

    dispatch_async(LYQueue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        NSString *lyrics = LYFetchLyrics(titleCopy, artistCopy, albumCopy, duration);
        if (LYHasText(lyrics)) {
            @synchronized(LYCache) {
                [LYCache setObject:lyrics forKey:keyCopy];
            }
            LYSaveCache();
            NSLog(@"[Lyricalizer LRCLIB] cached lyrics for %@ — %@", artistCopy, titleCopy);
        } else {
            NSLog(@"[Lyricalizer LRCLIB] no lyrics found for %@ — %@", artistCopy, titleCopy);
        }

        @synchronized(LYInflight) {
            [LYInflight removeObject:keyCopy];
        }

        [titleCopy release];
        [artistCopy release];
        [albumCopy release];
        [keyCopy release];
        [pool drain];
    });
}

%hook MPAVItem

- (id)lyrics {
    NSString *original = %orig;
    if (LYHasText(original)) return original;

    NSString *cached = LYCachedLyricsForItem(self);
    if (LYHasText(cached)) return cached;

    LYEnsureFetchForItem(self);

    // Returning non-empty text makes the classic Music app expose its native
    // lyrics sheet immediately while the modern backend fetches in background.
    return @"Downloading lyrics from LRCLIB…\n\nTap the artwork again in a moment.";
}

%end

%hook MusicNowPlayingViewController

- (id)_createContentViewForItem:(id)item contentViewController:(id *)contentViewController {
    if (item && [item respondsToSelector:@selector(mainTitle)]) {
        LYEnsureFetchForItem((MPAVItem *)item);
    }
    return %orig;
}

%end

%ctor {
    LYInitState();
}
