#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "LRHTTPS.h"
#include <math.h>
#include <unistd.h>

@interface MPAVItem : NSObject
- (NSString *)lyrics;
- (NSString *)mainTitle;
- (NSString *)artist;
- (NSString *)albumArtist;
- (NSString *)album;
- (double)durationInSeconds;
- (unsigned long long)persistentID;
@end

@interface MusicLyricsView : UIView
- (id)initWithFrame:(CGRect)frame;
- (void)setText:(NSString *)text;
- (void)setHidden:(BOOL)hidden animated:(BOOL)animated;
@end

@interface MusicNowPlayingViewController : UIViewController
- (id)_createContentViewForItem:(id)item contentViewController:(id *)contentViewController;
- (void)_tapAction:(id)sender;
- (void)_updateTitles;
@end

typedef enum {
    LYFetchTemporaryFailure = 0,
    LYFetchSuccess = 1,
    LYFetchConfirmedNoLyrics = 2
} LYFetchOutcome;

static NSString * const LYCachePath =
    @"/var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.cache.plist";
static NSString * const LYMissPath =
    @"/var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.miss.plist";
static NSString * const LYUserAgent =
    @"Lyricalizer-LRCLIB/4.0 (iOS 6 armv7; https://github.com/ac3xx/Lyricalizer)";
static const NSTimeInterval LYMissTTL = 12.0 * 60.0 * 60.0;

static NSMutableDictionary *LYCache = nil;
static NSMutableDictionary *LYMissCache = nil;
static NSMutableSet *LYInflight = nil;
static dispatch_queue_t LYQueue = NULL;

static char LYLyricsViewAssocKey;
static char LYVisibleAssocKey;
static char LYWantedAssocKey;

static BOOL LYHasText(id value) {
    if (!value || value == [NSNull null] || ![value isKindOfClass:[NSString class]]) return NO;
    NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [s length] > 0;
}

static NSString *LYSafeString(id value) {
    return LYHasText(value) ? (NSString *)value : @"";
}

static BOOL LYLooksLikeOldPlaceholder(NSString *text) {
    if (!LYHasText(text)) return YES;
    NSString *lower = [text lowercaseString];
    return [lower hasPrefix:@"downloading lyrics"] ||
           [lower hasPrefix:@"searching lyrics"] ||
           [lower hasPrefix:@"fetching lyrics"] ||
           [lower hasPrefix:@"no lyrics found"] ||
           [lower hasPrefix:@"instrumental track"] ||
           [lower hasPrefix:@"can't search lyrics"] ||
           [lower hasPrefix:@"could not connect"];
}

static void LYSaveDictionary(NSDictionary *dict, NSString *path) {
    NSDictionary *snapshot = nil;
    @synchronized(dict) {
        snapshot = [[NSDictionary alloc] initWithDictionary:dict];
    }
    [snapshot writeToFile:path atomically:YES];
    [snapshot release];
}

static void LYInitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:LYCachePath];
        LYCache = saved ? [saved mutableCopy] : [[NSMutableDictionary alloc] init];

        NSDictionary *misses = [NSDictionary dictionaryWithContentsOfFile:LYMissPath];
        LYMissCache = misses ? [misses mutableCopy] : [[NSMutableDictionary alloc] init];

        // Purge placeholder/error strings cached by experimental builds.
        NSMutableArray *badKeys = [NSMutableArray array];
        for (NSString *key in LYCache) {
            id value = [LYCache objectForKey:key];
            if (![value isKindOfClass:[NSString class]] || LYLooksLikeOldPlaceholder((NSString *)value)) {
                [badKeys addObject:key];
            }
        }
        if ([badKeys count]) {
            [LYCache removeObjectsForKeys:badKeys];
            LYSaveDictionary(LYCache, LYCachePath);
        }

        LYInflight = [[NSMutableSet alloc] init];
        LYQueue = dispatch_queue_create("com.ac3xx.lyricalizer.lrclib.fetch", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *LYPercentEncode(NSString *value) {
    if (!value) return @"";
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = (const unsigned char *)[data bytes];
    NSMutableString *out = [NSMutableString string];

    for (NSUInteger i = 0; i < [data length]; i++) {
        unsigned char c = bytes[i];
        BOOL unreserved =
            (c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            c == '-' || c == '.' || c == '_' || c == '~';
        if (unreserved) [out appendFormat:@"%c", c];
        else [out appendFormat:@"%%%02X", c];
    }
    return out;
}

static NSString *LYNormalize(NSString *value) {
    if (!value) return @"";

    NSMutableString *s = [[[value lowercaseString] mutableCopy] autorelease];

    // Ignore common edition/remaster text in brackets for safe matching.
    NSError *regexError = nil;
    NSRegularExpression *brackets =
        [NSRegularExpression regularExpressionWithPattern:@"\\([^\\)]*\\)|\\[[^\\]]*\\]"
                                                  options:0
                                                    error:&regexError];
    if (!regexError) {
        [brackets replaceMatchesInString:s
                                 options:0
                                   range:NSMakeRange(0, [s length])
                            withTemplate:@""];
    }

    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar ch = [s characterAtIndex:i];
        if ([allowed characterIsMember:ch]) [out appendFormat:@"%C", ch];
    }
    return out;
}

static NSString *LYPrimaryArtist(NSString *artist) {
    if (![artist length]) return @"";

    NSArray *separators = [NSArray arrayWithObjects:
        @" feat.", @" feat ", @" ft.", @" ft ", @" featuring ",
        @" & ", @" / ", @", ", @"; ", nil];

    NSString *lower = [artist lowercaseString];
    NSUInteger cut = [artist length];

    for (NSString *sep in separators) {
        NSRange r = [lower rangeOfString:sep];
        if (r.location != NSNotFound && r.location < cut) cut = r.location;
    }

    NSString *result = [artist substringToIndex:cut];
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static BOOL LYMetadataMatch(NSString *wantedTitle,
                            NSString *wantedArtist,
                            NSString *foundTitle,
                            NSString *foundArtist) {
    NSString *wt = LYNormalize(wantedTitle);
    NSString *wa = LYNormalize(LYPrimaryArtist(wantedArtist));
    NSString *ft = LYNormalize(foundTitle);
    NSString *fa = LYNormalize(LYPrimaryArtist(foundArtist));

    if (![wt length] || ![wa length] || ![ft length] || ![fa length]) return NO;

    BOOL titleMatch = [wt isEqualToString:ft] ||
        [wt rangeOfString:ft].location != NSNotFound ||
        [ft rangeOfString:wt].location != NSNotFound;

    BOOL artistMatch = [wa isEqualToString:fa] ||
        [wa rangeOfString:fa].location != NSNotFound ||
        [fa rangeOfString:wa].location != NSNotFound;

    return titleMatch && artistMatch;
}

static NSString *LYCacheKey(NSString *title,
                            NSString *artist,
                            NSString *album,
                            unsigned long long persistentID) {
    if (persistentID != 0ULL) return [NSString stringWithFormat:@"pid:%llu", persistentID];
    return [NSString stringWithFormat:@"meta:%@|%@|%@",
            [LYSafeString(title) lowercaseString],
            [LYSafeString(artist) lowercaseString],
            [LYSafeString(album) lowercaseString]];
}

static NSString *LYCachedLyrics(NSString *key) {
    LYInitState();
    if (!key) return nil;
    @synchronized(LYCache) {
        id value = [LYCache objectForKey:key];
        if (!LYHasText(value) || LYLooksLikeOldPlaceholder((NSString *)value)) return nil;
        return [[value retain] autorelease];
    }
}

static void LYStoreLyrics(NSString *key, NSString *lyrics) {
    if (!key || !LYHasText(lyrics) || LYLooksLikeOldPlaceholder(lyrics)) return;

    @synchronized(LYCache) {
        [LYCache setObject:lyrics forKey:key];
    }
    @synchronized(LYMissCache) {
        [LYMissCache removeObjectForKey:key];
    }
    LYSaveDictionary(LYCache, LYCachePath);
    LYSaveDictionary(LYMissCache, LYMissPath);
}

static BOOL LYMissIsFresh(NSString *key) {
    if (!key) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    @synchronized(LYMissCache) {
        NSNumber *stamp = [LYMissCache objectForKey:key];
        if (![stamp isKindOfClass:[NSNumber class]]) return NO;

        NSTimeInterval age = now - [stamp doubleValue];
        if (age >= 0 && age < LYMissTTL) return YES;

        [LYMissCache removeObjectForKey:key];
    }
    LYSaveDictionary(LYMissCache, LYMissPath);
    return NO;
}

static void LYMarkMiss(NSString *key) {
    if (!key) return;
    @synchronized(LYMissCache) {
        [LYMissCache setObject:
            [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]]
                          forKey:key];
    }
    LYSaveDictionary(LYMissCache, LYMissPath);
}

static NSData *LYRequestData(NSString *url,
                             NSString *accept,
                             NSInteger *statusOut,
                             NSString **errorOut) {
    NSInteger status = 0;
    NSInteger retryAfter = 0;
    NSString *error = nil;

    NSData *data = LYHTTPSDataForURL(url, LYUserAgent, accept,
                                     &status, &retryAfter, &error);

    // LRCLIB explicitly asks clients to honor Retry-After on 429/503.
    if (!data && (status == 429 || status == 503)) {
        NSInteger seconds = retryAfter > 0 ? retryAfter : 1;
        if (seconds > 5) seconds = 5;
        sleep((unsigned int)seconds);

        status = 0;
        retryAfter = 0;
        error = nil;
        data = LYHTTPSDataForURL(url, LYUserAgent, accept,
                                 &status, &retryAfter, &error);
    }

    if (statusOut) *statusOut = status;
    if (errorOut) *errorOut = error;
    return data;
}

static id LYJSONForURL(NSString *url,
                       NSInteger *statusOut,
                       NSString **errorOut) {
    NSInteger status = 0;
    NSString *networkError = nil;
    NSData *data = LYRequestData(url, @"application/json", &status, &networkError);

    if (statusOut) *statusOut = status;
    if (!data) {
        if (errorOut) *errorOut = networkError;
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"JSON parse failed: %@", jsonError];
        return nil;
    }

    return object;
}

static NSString *LYPlainFromSynced(NSString *synced) {
    if (!LYHasText(synced)) return nil;

    NSArray *lines = [synced componentsSeparatedByCharactersInSet:
                      [NSCharacterSet newlineCharacterSet]];
    NSMutableArray *plain = [NSMutableArray arrayWithCapacity:[lines count]];

    for (NSString *line in lines) {
        NSString *out = line;

        // Drop one or more LRC tags/timestamps at the beginning.
        while ([out hasPrefix:@"["]) {
            NSRange close = [out rangeOfString:@"]"];
            if (close.location == NSNotFound) break;
            if (close.location + 1 >= [out length]) {
                out = @"";
                break;
            }
            out = [out substringFromIndex:close.location + 1];
        }

        out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [plain addObject:out ?: @""];
    }

    NSString *joined = [plain componentsJoinedByString:@"\n"];
    return LYHasText(joined) ? joined : nil;
}

static BOOL LYLRCLIBRecordInstrumental(NSDictionary *record) {
    id value = [record objectForKey:@"instrumental"];
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSString *LYLyricsFromLRCLIBRecord(NSDictionary *record) {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;
    if (LYLRCLIBRecordInstrumental(record)) return nil;

    NSString *plain = [record objectForKey:@"plainLyrics"];
    if (LYHasText(plain)) return plain;

    NSString *synced = [record objectForKey:@"syncedLyrics"];
    if (LYHasText(synced)) return LYPlainFromSynced(synced);

    return nil;
}

static NSInteger LYScoreLRCLIBRecord(NSDictionary *record,
                                     NSString *title,
                                     NSString *artist,
                                     NSString *album,
                                     double duration) {
    if (![record isKindOfClass:[NSDictionary class]]) return NSIntegerMin;

    NSString *rt = LYSafeString([record objectForKey:@"trackName"]);
    NSString *ra = LYSafeString([record objectForKey:@"artistName"]);
    NSString *ral = LYSafeString([record objectForKey:@"albumName"]);

    if (!LYMetadataMatch(title, artist, rt, ra)) return NSIntegerMin;

    NSInteger score = 150;
    if ([[LYNormalize(title) description] isEqualToString:LYNormalize(rt)]) score += 60;
    if ([[LYNormalize(LYPrimaryArtist(artist)) description]
         isEqualToString:LYNormalize(LYPrimaryArtist(ra))]) score += 50;
    if ([album length] && [[LYNormalize(album) description] isEqualToString:LYNormalize(ral)]) score += 20;

    id d = [record objectForKey:@"duration"];
    if (duration > 0.0 && [d respondsToSelector:@selector(doubleValue)]) {
        double delta = fabs([d doubleValue] - duration);
        if (delta <= 2.0) score += 50;
        else if (delta <= 5.0) score += 25;
        else if (delta <= 10.0) score += 5;
    }

    if (LYLyricsFromLRCLIBRecord(record)) score += 10;
    return score;
}

static NSDictionary *LYBestLRCLIBRecord(NSArray *array,
                                         NSString *title,
                                         NSString *artist,
                                         NSString *album,
                                         double duration) {
    NSDictionary *best = nil;
    NSInteger bestScore = NSIntegerMin;

    for (id obj in array) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;

        NSInteger score = LYScoreLRCLIBRecord((NSDictionary *)obj,
                                              title, artist, album, duration);
        if (score > bestScore) {
            bestScore = score;
            best = obj;
        }
    }

    return best;
}

static NSString *LYLyricsFromLrcAPIArray(NSArray *array,
                                         NSString *title,
                                         NSString *artist) {
    for (id obj in array) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;

        NSString *rt = LYSafeString([obj objectForKey:@"title"]);
        NSString *ra = LYSafeString([obj objectForKey:@"artist"]);
        NSString *lyrics = LYSafeString([obj objectForKey:@"lyrics"]);

        if (LYMetadataMatch(title, artist, rt, ra) && LYHasText(lyrics)) {
            NSString *plain = LYPlainFromSynced(lyrics);
            return LYHasText(plain) ? plain : lyrics;
        }
    }
    return nil;
}

static void LYThrottle(void) {
    // LRCLIB recommends a small delay between sequential requests.
    usleep(350000);
}

static NSString *LYFetchLyrics(NSString *title,
                               NSString *artist,
                               NSString *album,
                               double duration,
                               LYFetchOutcome *outcome) {
    if (outcome) *outcome = LYFetchTemporaryFailure;
    if (![title length] || ![artist length]) return nil;

    BOOL definitiveResponse = NO;
    BOOL sawInstrumental = NO;
    NSInteger status = 0;
    NSString *error = nil;
    id obj = nil;

    // 1) LRCLIB exact signature: title + artist + album + duration.
    NSMutableString *exact = [NSMutableString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@&artist_name=%@",
        LYPercentEncode(title), LYPercentEncode(artist)];

    if ([album length]) [exact appendFormat:@"&album_name=%@", LYPercentEncode(album)];
    if (duration >= 1.0 && duration <= 3600.0)
        [exact appendFormat:@"&duration=%.0f", duration];

    obj = LYJSONForURL(exact, &status, &error);
    if ((status >= 200 && status < 300) || status == 404) definitiveResponse = YES;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *record = (NSDictionary *)obj;
        if (LYLRCLIBRecordInstrumental(record)) sawInstrumental = YES;
        NSString *lyrics = LYLyricsFromLRCLIBRecord(record);
        if (lyrics) {
            if (outcome) *outcome = LYFetchSuccess;
            return lyrics;
        }
    }

    LYThrottle();

    // 2) Retry LRCLIB exact matching without album/duration in case local tags
    // describe a different edition/remaster.
    NSString *simpleGet = [NSString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@&artist_name=%@",
        LYPercentEncode(title), LYPercentEncode(artist)];

    status = 0; error = nil;
    obj = LYJSONForURL(simpleGet, &status, &error);
    if ((status >= 200 && status < 300) || status == 404) definitiveResponse = YES;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *record = (NSDictionary *)obj;
        if (LYLRCLIBRecordInstrumental(record)) sawInstrumental = YES;
        NSString *lyrics = LYLyricsFromLRCLIBRecord(record);
        if (lyrics) {
            if (outcome) *outcome = LYFetchSuccess;
            return lyrics;
        }
    }

    LYThrottle();

    // 3) LRCLIB structured search, then choose only a safe metadata match.
    NSString *structured = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?track_name=%@&artist_name=%@",
        LYPercentEncode(title), LYPercentEncode(artist)];

    status = 0; error = nil;
    obj = LYJSONForURL(structured, &status, &error);
    if (status >= 200 && status < 300) definitiveResponse = YES;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSDictionary *record = LYBestLRCLIBRecord((NSArray *)obj, title, artist, album, duration);
        if (record) {
            if (LYLRCLIBRecordInstrumental(record)) sawInstrumental = YES;
            NSString *lyrics = LYLyricsFromLRCLIBRecord(record);
            if (lyrics) {
                if (outcome) *outcome = LYFetchSuccess;
                return lyrics;
            }
        }
    }

    LYThrottle();

    // 4) LRCLIB free-text search catches punctuation / edition naming differences.
    NSString *query = [NSString stringWithFormat:@"%@ %@", artist, title];
    NSString *fuzzy = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?q=%@", LYPercentEncode(query)];

    status = 0; error = nil;
    obj = LYJSONForURL(fuzzy, &status, &error);
    if (status >= 200 && status < 300) definitiveResponse = YES;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSDictionary *record = LYBestLRCLIBRecord((NSArray *)obj, title, artist, album, duration);
        if (record) {
            if (LYLRCLIBRecordInstrumental(record)) sawInstrumental = YES;
            NSString *lyrics = LYLyricsFromLRCLIBRecord(record);
            if (lyrics) {
                if (outcome) *outcome = LYFetchSuccess;
                return lyrics;
            }
        }
    }

    // 5) lyrics.ovh is itself a multi-source community aggregator (Genius,
    // AZLyrics, Paroles.net, LyricsMania, Letras, Lyrics.com) and also retries
    // normalized title/primary-artist variants server-side.
    NSString *ovh = [NSString stringWithFormat:
        @"https://api.lyrics.ovh/v1/%@/%@",
        LYPercentEncode(artist), LYPercentEncode(title)];

    status = 0; error = nil;
    obj = LYJSONForURL(ovh, &status, &error);
    if ((status >= 200 && status < 300) || status == 404) definitiveResponse = YES;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSString *lyrics = [obj objectForKey:@"lyrics"];
        if (LYHasText(lyrics)) {
            if (outcome) *outcome = LYFetchSuccess;
            return lyrics;
        }
    }

    // 6) Last-resort public LrcAPI search. It can be slower and less accurate,
    // so accept only title+artist matches and strip LRC timestamps locally.
    NSMutableString *lrc = [NSMutableString stringWithFormat:
        @"https://api.lrc.cx/api/v1/lyrics/advance?title=%@&artist=%@",
        LYPercentEncode(title), LYPercentEncode(artist)];
    if ([album length]) [lrc appendFormat:@"&album=%@", LYPercentEncode(album)];

    status = 0; error = nil;
    obj = LYJSONForURL(lrc, &status, &error);
    if (status >= 200 && status < 300) definitiveResponse = YES;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSString *lyrics = LYLyricsFromLrcAPIArray((NSArray *)obj, title, artist);
        if (lyrics) {
            if (outcome) *outcome = LYFetchSuccess;
            return lyrics;
        }
    }

    if (outcome) {
        // Instrumental is deliberately treated exactly like "no lyrics":
        // no overlay, no placeholder, just the normal artwork.
        *outcome = (definitiveResponse || sawInstrumental)
            ? LYFetchConfirmedNoLyrics
            : LYFetchTemporaryFailure;
    }
    return nil;
}

static id LYGetObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static MPAVItem *LYCurrentItem(MusicNowPlayingViewController *vc) {
    return (MPAVItem *)LYGetObjectIvar(vc, "_item");
}

static void LYMetadataForItem(MPAVItem *item,
                              NSString **title,
                              NSString **artist,
                              NSString **album,
                              double *duration,
                              unsigned long long *pid) {
    NSString *t = @"", *ar = @"", *al = @"";
    double d = 0.0;
    unsigned long long p = 0ULL;

    if ([item respondsToSelector:@selector(mainTitle)]) t = LYSafeString([item mainTitle]);
    if ([item respondsToSelector:@selector(artist)]) ar = LYSafeString([item artist]);
    if (![ar length] && [item respondsToSelector:@selector(albumArtist)])
        ar = LYSafeString([item albumArtist]);
    if ([item respondsToSelector:@selector(album)]) al = LYSafeString([item album]);
    if ([item respondsToSelector:@selector(durationInSeconds)]) d = [item durationInSeconds];
    if ([item respondsToSelector:@selector(persistentID)]) p = [item persistentID];

    if (title) *title = t;
    if (artist) *artist = ar;
    if (album) *album = al;
    if (duration) *duration = d;
    if (pid) *pid = p;
}

static NSString *LYKeyForItem(MPAVItem *item) {
    NSString *title = nil, *artist = nil, *album = nil;
    double duration = 0.0;
    unsigned long long pid = 0ULL;
    LYMetadataForItem(item, &title, &artist, &album, &duration, &pid);
    return LYCacheKey(title, artist, album, pid);
}

static MusicLyricsView *LYLyricsViewForController(MusicNowPlayingViewController *vc,
                                                   BOOL create) {
    MusicLyricsView *view =
        (MusicLyricsView *)objc_getAssociatedObject(vc, &LYLyricsViewAssocKey);
    if (view) return view;

    id native = LYGetObjectIvar(vc, "_lyricsView");
    Class lyricsClass = NSClassFromString(@"MusicLyricsView");

    if (native && lyricsClass && [native isKindOfClass:lyricsClass]) {
        view = (MusicLyricsView *)native;
        objc_setAssociatedObject(vc, &LYLyricsViewAssocKey, view,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return view;
    }

    if (!create || !lyricsClass) return nil;

    UIView *content = (UIView *)LYGetObjectIvar(vc, "_contentView");
    if (!content) content = [vc view];

    view = [[[lyricsClass alloc] initWithFrame:[content bounds]] autorelease];
    [view setHidden:YES animated:NO];
    [content addSubview:view];

    objc_setAssociatedObject(vc, &LYLyricsViewAssocKey, view,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

static BOOL LYBoolAssoc(id object, char *key) {
    NSNumber *n = (NSNumber *)objc_getAssociatedObject(object, key);
    return n ? [n boolValue] : NO;
}

static void LYSetBoolAssoc(id object, char *key, BOOL value) {
    objc_setAssociatedObject(object, key, [NSNumber numberWithBool:value],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL LYIsVisible(MusicNowPlayingViewController *vc) {
    return LYBoolAssoc(vc, &LYVisibleAssocKey);
}

static BOOL LYIsWanted(MusicNowPlayingViewController *vc) {
    return LYBoolAssoc(vc, &LYWantedAssocKey);
}

static void LYSetVisible(MusicNowPlayingViewController *vc, BOOL value) {
    LYSetBoolAssoc(vc, &LYVisibleAssocKey, value);
}

static void LYSetWanted(MusicNowPlayingViewController *vc, BOOL value) {
    LYSetBoolAssoc(vc, &LYWantedAssocKey, value);
}

static void LYHideLyricsView(MusicNowPlayingViewController *vc, BOOL animated) {
    MusicLyricsView *view = LYLyricsViewForController(vc, NO);
    if (view) [view setHidden:YES animated:animated];
    LYSetVisible(vc, NO);
    LYSetWanted(vc, NO);
}

static void LYShowLyricsText(MusicNowPlayingViewController *vc, NSString *text) {
    if (!vc || !LYHasText(text)) return;

    MusicLyricsView *view = LYLyricsViewForController(vc, YES);
    if (!view) return;

    [view setText:text];
    [view setHidden:NO animated:YES];
    LYSetVisible(vc, YES);
    LYSetWanted(vc, NO);
}

static void LYEnsureFetch(MusicNowPlayingViewController *vc,
                          MPAVItem *item,
                          BOOL userRequested) {
    if (!item) return;
    LYInitState();

    NSString *embedded = nil;
    if ([item respondsToSelector:@selector(lyrics)]) embedded = [item lyrics];
    if (LYHasText(embedded)) {
        if (userRequested) LYShowLyricsText(vc, embedded);
        return;
    }

    NSString *title = nil, *artist = nil, *album = nil;
    double duration = 0.0;
    unsigned long long pid = 0ULL;
    LYMetadataForItem(item, &title, &artist, &album, &duration, &pid);

    NSString *key = LYCacheKey(title, artist, album, pid);
    NSString *cached = LYCachedLyrics(key);
    if (cached) {
        if (userRequested) LYShowLyricsText(vc, cached);
        return;
    }

    // A recent confirmed miss behaves exactly like stock iOS with no lyrics:
    // leave the artwork alone and do not show a blank/error overlay.
    if (LYMissIsFresh(key)) {
        if (userRequested) LYSetWanted(vc, NO);
        return;
    }

    if (![title length] || ![artist length]) {
        if (userRequested) LYSetWanted(vc, NO);
        return;
    }

    if (userRequested) LYSetWanted(vc, YES);

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

        LYFetchOutcome outcome = LYFetchTemporaryFailure;
        NSString *lyrics = LYFetchLyrics(titleCopy, artistCopy, albumCopy,
                                         duration, &outcome);

        if (outcome == LYFetchSuccess && LYHasText(lyrics)) {
            LYStoreLyrics(keyCopy, lyrics);
        } else if (outcome == LYFetchConfirmedNoLyrics) {
            LYMarkMiss(keyCopy);
        }

        @synchronized(LYInflight) {
            [LYInflight removeObject:keyCopy];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            MPAVItem *current = LYCurrentItem(vc);
            NSString *currentKey = current ? LYKeyForItem(current) : nil;
            if (!currentKey || ![currentKey isEqualToString:keyCopy]) return;

            if (outcome == LYFetchSuccess && LYHasText(lyrics) && LYIsWanted(vc)) {
                LYShowLyricsText(vc, lyrics);
            } else if (outcome != LYFetchSuccess && LYIsWanted(vc)) {
                // Important: NO "Downloading", "No lyrics", or blank lyrics pane.
                // Keep the native artwork exactly as it was.
                LYHideLyricsView(vc, NO);
            }
        });

        [titleCopy release];
        [artistCopy release];
        [albumCopy release];
        [keyCopy release];
        [pool drain];
    });
}

%hook MusicNowPlayingViewController

- (id)_createContentViewForItem:(id)item contentViewController:(id *)contentViewController {
    id result = %orig;

    // Silent prefetch: most lyrics are already cached by the time artwork is tapped.
    if (item) LYEnsureFetch(self, (MPAVItem *)item, NO);
    return result;
}

- (void)_tapAction:(id)sender {
    if (LYIsVisible(self)) {
        LYHideLyricsView(self, YES);
        return;
    }

    MPAVItem *item = LYCurrentItem(self);
    if (!item) {
        %orig;
        return;
    }

    NSString *embedded = [item respondsToSelector:@selector(lyrics)] ? [item lyrics] : nil;
    NSString *cached = LYCachedLyrics(LYKeyForItem(item));

    if (LYHasText(embedded)) {
        LYShowLyricsText(self, embedded);
        return;
    }

    if (LYHasText(cached)) {
        LYShowLyricsText(self, cached);
        return;
    }

    // No placeholder. Search silently; only open the native lyric view if real
    // lyrics are actually found. If not, artwork remains untouched.
    LYEnsureFetch(self, item, YES);
}

- (void)_updateTitles {
    %orig;

    // New track: return to the normal artwork immediately, then prefetch.
    LYHideLyricsView(self, NO);
    MPAVItem *item = LYCurrentItem(self);
    if (item) LYEnsureFetch(self, item, NO);
}

%end

%ctor {
    LYInitState();
}
