#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "LRHTTPS.h"
#include <math.h>

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
- (void)_tapAction:(id)sender;
- (void)_updateTitles;
@end

static NSString * const LYCachePath = @"/var/mobile/Library/Preferences/com.ac3xx.lyricalizer.lrclib.cache.plist";
static NSString * const LYUserAgent = @"Lyricalizer-LRCLIB/3.0 (iOS 6 armv7 community port)";

static NSMutableDictionary *LYCache = nil;
static NSMutableSet *LYInflight = nil;
static dispatch_queue_t LYQueue = NULL;

static char LYLyricsViewAssocKey;
static char LYVisibleAssocKey;

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
    if (!value || value == [NSNull null] || ![value isKindOfClass:[NSString class]]) return NO;
    NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [s length] > 0;
}

static NSString *LYSafeString(id value) {
    return LYHasText(value) ? (NSString *)value : @"";
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

static NSString *LYCacheKey(NSString *title, NSString *artist, NSString *album, unsigned long long persistentID) {
    if (persistentID != 0ULL) return [NSString stringWithFormat:@"pid:%llu", persistentID];
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

static NSString *LYCachedLyrics(NSString *key) {
    LYInitState();
    if (!key) return nil;
    @synchronized(LYCache) {
        id value = [LYCache objectForKey:key];
        return LYHasText(value) ? [[value retain] autorelease] : nil;
    }
}

static void LYStoreLyrics(NSString *key, NSString *lyrics) {
    if (!key || !LYHasText(lyrics)) return;
    @synchronized(LYCache) {
        [LYCache setObject:lyrics forKey:key];
    }
    LYSaveCache();
}

static id LYJSONForURL(NSString *urlString, NSInteger *statusCode, NSString **errorString) {
    NSString *networkError = nil;
    NSData *data = LYHTTPSDataForURL(urlString, LYUserAgent, statusCode, &networkError);
    if (!data) {
        if (errorString) *errorString = networkError;
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError) {
        if (errorString) *errorString = [NSString stringWithFormat:@"JSON parse failed: %@", jsonError];
        return nil;
    }
    return object;
}

static NSString *LYPlainFromSynced(NSString *synced) {
    if (!LYHasText(synced)) return nil;
    NSArray *lines = [synced componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *plain = [NSMutableArray arrayWithCapacity:[lines count]];

    for (NSString *line in lines) {
        NSString *out = line;
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

static NSString *LYLyricsFromLRCLIBRecord(NSDictionary *record) {
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
    NSString *rt = LYSafeString([record objectForKey:@"trackName"]);
    NSString *ra = LYSafeString([record objectForKey:@"artistName"]);
    NSString *ral = LYSafeString([record objectForKey:@"albumName"]);

    if ([rt caseInsensitiveCompare:title] == NSOrderedSame) score += 100;
    else if ([[rt lowercaseString] rangeOfString:[[title lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]].location != NSNotFound) score += 35;

    if ([ra caseInsensitiveCompare:artist] == NSOrderedSame) score += 80;
    else if ([[ra lowercaseString] rangeOfString:[[artist lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]].location != NSNotFound) score += 25;

    if ([album length] && [ral caseInsensitiveCompare:album] == NSOrderedSame) score += 20;

    id d = [record objectForKey:@"duration"];
    if (duration > 0 && [d respondsToSelector:@selector(doubleValue)]) {
        double delta = fabs([d doubleValue] - duration);
        if (delta <= 2.0) score += 40;
        else if (delta <= 5.0) score += 20;
        else if (delta <= 10.0) score += 5;
    }

    if (LYLyricsFromLRCLIBRecord(record)) score += 10;
    return score;
}

static NSString *LYBestLyricsFromArray(NSArray *array,
                                       NSString *title,
                                       NSString *artist,
                                       NSString *album,
                                       double duration) {
    NSDictionary *best = nil;
    NSInteger bestScore = NSIntegerMin;

    for (id obj in array) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSInteger score = LYScoreRecord(obj, title, artist, album, duration);
        if (!best || score > bestScore) {
            best = obj;
            bestScore = score;
        }
    }
    return LYLyricsFromLRCLIBRecord(best);
}

static NSString *LYFetchLyrics(NSString *title,
                               NSString *artist,
                               NSString *album,
                               double duration,
                               NSString **failureReason) {
    if (![title length] || ![artist length]) {
        if (failureReason) *failureReason = @"Missing title or artist metadata.";
        return nil;
    }

    BOOL reachedService = NO;
    NSString *lastError = nil;
    NSInteger status = 0;

    NSMutableString *exact = [NSMutableString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@&artist_name=%@",
        LYPercentEncode(title), LYPercentEncode(artist)];

    if ([album length]) [exact appendFormat:@"&album_name=%@", LYPercentEncode(album)];
    if (duration >= 1.0 && duration <= 3600.0) [exact appendFormat:@"&duration=%.0f", duration];

    id obj = LYJSONForURL(exact, &status, &lastError);
    if (status > 0) reachedService = YES;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSString *lyrics = LYLyricsFromLRCLIBRecord(obj);
        if (lyrics) return lyrics;
    }

    NSString *searchURL = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?track_name=%@&artist_name=%@",
        LYPercentEncode(title), LYPercentEncode(artist)];

    status = 0; lastError = nil;
    obj = LYJSONForURL(searchURL, &status, &lastError);
    if (status > 0) reachedService = YES;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSString *lyrics = LYBestLyricsFromArray(obj, title, artist, album, duration);
        if (lyrics) return lyrics;
    }

    NSString *query = [NSString stringWithFormat:@"%@ %@", artist, title];
    NSString *fuzzyURL = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?q=%@", LYPercentEncode(query)];

    status = 0; lastError = nil;
    obj = LYJSONForURL(fuzzyURL, &status, &lastError);
    if (status > 0) reachedService = YES;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSString *lyrics = LYBestLyricsFromArray(obj, title, artist, album, duration);
        if (lyrics) return lyrics;
    }

    // Independent community fallback. Same bundled TLS engine, no external tweak.
    NSString *ovhURL = [NSString stringWithFormat:
        @"https://api.lyrics.ovh/v1/%@/%@",
        LYPercentEncode(artist), LYPercentEncode(title)];

    status = 0; lastError = nil;
    obj = LYJSONForURL(ovhURL, &status, &lastError);
    if (status > 0) reachedService = YES;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSString *lyrics = [obj objectForKey:@"lyrics"];
        if (LYHasText(lyrics)) return lyrics;
    }

    if (failureReason) {
        if (reachedService) *failureReason = @"No lyrics found for this track.";
        else *failureReason = lastError ?: @"Could not connect to the lyrics service.";
    }
    return nil;
}

static id LYGetObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static MPAVItem *LYCurrentItem(MusicNowPlayingViewController *vc) {
    id item = LYGetObjectIvar(vc, "_item");
    return [item isKindOfClass:NSClassFromString(@"MPAVItem")] ? (MPAVItem *)item : (MPAVItem *)item;
}

static void LYMetadataForItem(MPAVItem *item,
                              NSString **title,
                              NSString **artist,
                              NSString **album,
                              double *duration,
                              unsigned long long *pid) {
    NSString *t = @"", *ar = @"", *al = @"";
    double d = 0;
    unsigned long long p = 0;

    if ([item respondsToSelector:@selector(mainTitle)]) t = LYSafeString([item mainTitle]);
    if ([item respondsToSelector:@selector(artist)]) ar = LYSafeString([item artist]);
    if (![ar length] && [item respondsToSelector:@selector(albumArtist)]) ar = LYSafeString([item albumArtist]);
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
    double duration = 0;
    unsigned long long pid = 0;
    LYMetadataForItem(item, &title, &artist, &album, &duration, &pid);
    return LYCacheKey(title, artist, album, pid);
}

static MusicLyricsView *LYLyricsViewForController(MusicNowPlayingViewController *vc, BOOL create) {
    MusicLyricsView *view = (MusicLyricsView *)objc_getAssociatedObject(vc, &LYLyricsViewAssocKey);
    if (view) return view;

    id native = LYGetObjectIvar(vc, "_lyricsView");
    Class lyricsClass = NSClassFromString(@"MusicLyricsView");
    if (native && lyricsClass && [native isKindOfClass:lyricsClass]) {
        view = (MusicLyricsView *)native;
        objc_setAssociatedObject(vc, &LYLyricsViewAssocKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return view;
    }

    if (!create || !lyricsClass) return nil;

    UIView *content = (UIView *)LYGetObjectIvar(vc, "_contentView");
    if (!content) content = [vc view];

    view = [[[lyricsClass alloc] initWithFrame:[content bounds]] autorelease];
    [view setHidden:YES animated:NO];
    [content addSubview:view];
    objc_setAssociatedObject(vc, &LYLyricsViewAssocKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

static BOOL LYIsVisible(MusicNowPlayingViewController *vc) {
    NSNumber *n = (NSNumber *)objc_getAssociatedObject(vc, &LYVisibleAssocKey);
    return n ? [n boolValue] : NO;
}

static void LYSetVisible(MusicNowPlayingViewController *vc, BOOL visible) {
    objc_setAssociatedObject(vc, &LYVisibleAssocKey,
                             [NSNumber numberWithBool:visible],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LYUpdateVisibleLyrics(MusicNowPlayingViewController *vc, NSString *key, NSString *text) {
    if (!vc || !key || !text) return;
    MPAVItem *current = LYCurrentItem(vc);
    if (!current || ![[LYKeyForItem(current) description] isEqualToString:key]) return;
    if (!LYIsVisible(vc)) return;

    MusicLyricsView *view = LYLyricsViewForController(vc, YES);
    [view setText:text];
    [view setHidden:NO animated:NO];
}

static void LYStartFetch(MusicNowPlayingViewController *vc, MPAVItem *item, MusicLyricsView *view) {
    LYInitState();

    NSString *title = nil, *artist = nil, *album = nil;
    double duration = 0;
    unsigned long long pid = 0;
    LYMetadataForItem(item, &title, &artist, &album, &duration, &pid);
    NSString *key = LYCacheKey(title, artist, album, pid);

    if (![title length] || ![artist length]) {
        [view setText:@"Can't search lyrics: this track is missing title or artist metadata."];
        return;
    }

    @synchronized(LYInflight) {
        if ([LYInflight containsObject:key]) {
            [view setText:@"Searching lyrics…"];
            return;
        }
        [LYInflight addObject:key];
    }

    [view setText:@"Searching lyrics…"];

    NSString *titleCopy = [title copy];
    NSString *artistCopy = [artist copy];
    NSString *albumCopy = [album copy];
    NSString *keyCopy = [key copy];

    dispatch_async(LYQueue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        NSString *reason = nil;
        NSString *lyrics = LYFetchLyrics(titleCopy, artistCopy, albumCopy, duration, &reason);

        if (LYHasText(lyrics)) {
            LYStoreLyrics(keyCopy, lyrics);
        }

        NSString *display = LYHasText(lyrics) ? lyrics : (reason ?: @"No lyrics found for this track.");

        dispatch_async(dispatch_get_main_queue(), ^{
            LYUpdateVisibleLyrics(vc, keyCopy, display);
        });

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

static void LYShowLyrics(MusicNowPlayingViewController *vc) {
    MPAVItem *item = LYCurrentItem(vc);
    if (!item) return;

    MusicLyricsView *view = LYLyricsViewForController(vc, YES);
    if (!view) return;

    NSString *embedded = nil;
    if ([item respondsToSelector:@selector(lyrics)]) embedded = [item lyrics];

    NSString *key = LYKeyForItem(item);
    NSString *cached = LYCachedLyrics(key);

    if (LYHasText(embedded)) {
        [view setText:embedded];
    } else if (LYHasText(cached)) {
        [view setText:cached];
    } else {
        LYStartFetch(vc, item, view);
    }

    [view setHidden:NO animated:YES];
    LYSetVisible(vc, YES);
}

%hook MusicNowPlayingViewController

- (void)_tapAction:(id)sender {
    if (LYIsVisible(self)) {
        MusicLyricsView *view = LYLyricsViewForController(self, NO);
        if (view) [view setHidden:YES animated:YES];
        LYSetVisible(self, NO);
        return;
    }

    LYShowLyrics(self);
}

- (void)_updateTitles {
    %orig;

    if (LYIsVisible(self)) {
        MusicLyricsView *view = LYLyricsViewForController(self, NO);
        if (view) [view setHidden:YES animated:NO];
        LYSetVisible(self, NO);
    }
}

%end

%ctor {
    LYInitState();
}
