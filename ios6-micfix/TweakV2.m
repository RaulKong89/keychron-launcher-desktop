#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <stdint.h>
#import <limits.h>

typedef void (*MSHookMessageExFn)(Class, SEL, IMP, IMP *);
typedef void (*MSHookFunctionFn)(void *, void *, void **);

typedef int32_t OSStatus;
typedef uint32_t AudioSessionPropertyID;
typedef uint32_t UInt32;
typedef unsigned char Boolean;

typedef OSStatus (*AudioSessionSetPropertyFn)(AudioSessionPropertyID, UInt32, const void *);
typedef OSStatus (*AudioSessionSetActiveFn)(Boolean);
typedef OSStatus (*AudioSessionSetActiveWithFlagsFn)(Boolean, UInt32);

static MSHookMessageExFn pMSHookMessageEx = NULL;
static MSHookFunctionFn pMSHookFunction = NULL;

static BOOL (*orig_setMode)(id, SEL, NSString *, NSError **) = NULL;
static BOOL (*orig_setActive)(id, SEL, BOOL, NSError **) = NULL;
static BOOL (*orig_setActiveWithOptions)(id, SEL, BOOL, NSUInteger, NSError **) = NULL;
static BOOL (*orig_setCategory)(id, SEL, NSString *, NSError **) = NULL;
static BOOL (*orig_setCategoryWithOptions)(id, SEL, NSString *, NSUInteger, NSError **) = NULL;
static BOOL (*orig_setInputDataSource)(id, SEL, id, NSError **) = NULL;
static BOOL (*orig_overrideOutputAudioPort)(id, SEL, NSUInteger, NSError **) = NULL;

static AudioSessionSetPropertyFn orig_AudioSessionSetProperty = NULL;
static AudioSessionSetActiveFn orig_AudioSessionSetActive = NULL;
static AudioSessionSetActiveWithFlagsFn orig_AudioSessionSetActiveWithFlags = NULL;

static BOOL gIsTarget = NO;
static BOOL gApplying = NO;
static id gObserver = nil;

// Apple's stable data-source ID used for the bottom built-in microphone ("mc01").
// This is preferable to the localized dataSourceName on iOS 6.
static const unsigned long long kBottomMicDataSourceID = 1835216945ULL;

static void RKLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[[NSString alloc] initWithFormat:fmt arguments:ap] autorelease];
    va_end(ap);
    NSLog(@"[BottomMicRedirect v2] %@", body);
}

static BOOL RKIsIPhone4S(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return NO;
    char *machine = (char *)malloc(size);
    if (!machine) return NO;
    BOOL match = NO;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        match = (strcmp(machine, "iPhone4,1") == 0);
    }
    free(machine);
    return match;
}

static BOOL RKRouteUsesBuiltInMic(AVAudioSession *session) {
    @try {
        AVAudioSessionRouteDescription *route = [session currentRoute];
        for (AVAudioSessionPortDescription *port in [route inputs]) {
            NSString *type = [port portType];
            if ([type isEqualToString:AVAudioSessionPortBuiltInMic]) return YES;
        }
    } @catch (...) {
    }
    return NO;
}

static AVAudioSessionDataSourceDescription *RKFindBottomSource(AVAudioSession *session) {
    NSArray *sources = nil;
    @try {
        sources = [session inputDataSources];
    } @catch (...) {
        return nil;
    }

    if (![sources count]) return nil;

    AVAudioSessionDataSourceDescription *nameMatch = nil;
    AVAudioSessionDataSourceDescription *lowestID = nil;
    unsigned long long lowest = ULLONG_MAX;

    for (AVAudioSessionDataSourceDescription *source in sources) {
        NSNumber *n = nil;
        NSString *name = nil;

        @try {
            n = [source dataSourceID];
            name = [source dataSourceName];
        } @catch (...) {
        }

        unsigned long long v = n ? [n unsignedLongLongValue] : ULLONG_MAX;

        if (v == kBottomMicDataSourceID) {
            return source;
        }

        if (name && [name caseInsensitiveCompare:@"Bottom"] == NSOrderedSame) {
            nameMatch = source;
        }

        if (v < lowest) {
            lowest = v;
            lowestID = source;
        }
    }

    if (nameMatch) return nameMatch;

    // On iPhone 4/4S the built-in mic exposes bottom/top sources. If the label is
    // localized, the lower system ID is the safest iOS 6 fallback.
    if (RKRouteUsesBuiltInMic(session) && [sources count] >= 2 && [sources count] <= 3) {
        return lowestID;
    }

    return nil;
}

static BOOL RKApplyBottomNow(NSString *reason) {
    if (!gIsTarget || gApplying) return NO;
    if (!orig_setInputDataSource) return NO;

    gApplying = YES;
    BOOL changed = NO;

    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        AVAudioSessionDataSourceDescription *bottom = RKFindBottomSource(session);

        // If VideoRecording temporarily exposes no selectable bottom source,
        // switch only that mode to Default as a fallback, then try again.
        if (!bottom && orig_setMode) {
            NSString *mode = [session mode];
            if ([mode isEqualToString:AVAudioSessionModeVideoRecording]) {
                NSError *modeError = nil;
                BOOL ok = orig_setMode(session, @selector(setMode:error:),
                                       AVAudioSessionModeDefault, &modeError);
                RKLog(@"fallback mode VideoRecording -> Default: %@ (%@)",
                      ok ? @"OK" : @"FAIL", modeError);
                bottom = RKFindBottomSource(session);
            }
        }

        if (bottom) {
            NSNumber *targetID = [bottom dataSourceID];
            NSString *targetName = [bottom dataSourceName];
            AVAudioSessionDataSourceDescription *current = nil;

            @try {
                current = [session inputDataSource];
            } @catch (...) {
            }

            NSNumber *currentID = current ? [current dataSourceID] : nil;

            if (!currentID || ![currentID isEqualToNumber:targetID]) {
                NSError *err = nil;
                BOOL ok = orig_setInputDataSource(session,
                                                  @selector(setInputDataSource:error:),
                                                  bottom, &err);
                RKLog(@"force bottom reason=%@ target=%@/%@ current=%@ -> %@ (%@)",
                      reason, targetName, targetID, currentID,
                      ok ? @"OK" : @"FAIL", err);
                changed = ok;
            }
        }
    } @catch (NSException *e) {
        RKLog(@"exception while forcing bottom mic: %@", e);
    }

    gApplying = NO;
    return changed;
}

static void RKDelayedForce(void *context) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *reason = context ? (NSString *)context : @"delayed";
    RKApplyBottomNow(reason);
    [reason release];
    [pool drain];
}

static void RKScheduleOne(double seconds, NSString *reason) {
    NSString *copy = [reason copy];
    int64_t delta = (int64_t)(seconds * (double)NSEC_PER_SEC);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, delta),
                     dispatch_get_main_queue(),
                     copy,
                     RKDelayedForce);
}

static void RKScheduleForces(NSString *reason) {
    if (!gIsTarget) return;
    RKScheduleOne(0.00, reason);
    RKScheduleOne(0.08, reason);
    RKScheduleOne(0.25, reason);
    RKScheduleOne(0.75, reason);
    RKScheduleOne(1.50, reason);
}

@interface RKBottomMicObserver : NSObject
@end

@implementation RKBottomMicObserver
- (void)routeChanged:(NSNotification *)note {
    RKScheduleForces(@"route-change");
}
- (void)mediaReset:(NSNotification *)note {
    RKScheduleForces(@"media-reset");
}
- (void)interruption:(NSNotification *)note {
    RKScheduleForces(@"interruption");
}
@end

static BOOL hook_setMode(id self, SEL _cmd, NSString *mode, NSError **error) {
    BOOL ok = orig_setMode ? orig_setMode(self, _cmd, mode, error) : NO;
    if (ok) RKScheduleForces([NSString stringWithFormat:@"setMode:%@", mode]);
    return ok;
}

static BOOL hook_setActive(id self, SEL _cmd, BOOL active, NSError **error) {
    BOOL ok = orig_setActive ? orig_setActive(self, _cmd, active, error) : NO;
    if (ok && active) RKScheduleForces(@"setActive");
    return ok;
}

static BOOL hook_setActiveWithOptions(id self, SEL _cmd, BOOL active, NSUInteger options, NSError **error) {
    BOOL ok = orig_setActiveWithOptions ? orig_setActiveWithOptions(self, _cmd, active, options, error) : NO;
    if (ok && active) RKScheduleForces(@"setActive:withOptions:");
    return ok;
}

static BOOL hook_setCategory(id self, SEL _cmd, NSString *category, NSError **error) {
    BOOL ok = orig_setCategory ? orig_setCategory(self, _cmd, category, error) : NO;
    if (ok) RKScheduleForces([NSString stringWithFormat:@"setCategory:%@", category]);
    return ok;
}

static BOOL hook_setCategoryWithOptions(id self, SEL _cmd, NSString *category, NSUInteger options, NSError **error) {
    BOOL ok = orig_setCategoryWithOptions ? orig_setCategoryWithOptions(self, _cmd, category, options, error) : NO;
    if (ok) RKScheduleForces([NSString stringWithFormat:@"setCategoryOptions:%@", category]);
    return ok;
}

static BOOL hook_setInputDataSource(id self, SEL _cmd, id requested, NSError **error) {
    id chosen = requested;

    if (!gApplying) {
        @try {
            id bottom = RKFindBottomSource((AVAudioSession *)self);
            if (bottom) chosen = bottom;
        } @catch (...) {
        }
    }

    BOOL ok = orig_setInputDataSource ?
        orig_setInputDataSource(self, _cmd, chosen, error) : NO;

    if (ok) RKScheduleForces(@"setInputDataSource");
    return ok;
}

static BOOL hook_overrideOutputAudioPort(id self, SEL _cmd, NSUInteger port, NSError **error) {
    BOOL ok = orig_overrideOutputAudioPort ?
        orig_overrideOutputAudioPort(self, _cmd, port, error) : NO;

    if (ok) RKScheduleForces(@"speaker-route-change");
    return ok;
}

static OSStatus hook_AudioSessionSetProperty(AudioSessionPropertyID prop,
                                             UInt32 size,
                                             const void *data) {
    OSStatus status = orig_AudioSessionSetProperty ?
        orig_AudioSessionSetProperty(prop, size, data) : (OSStatus)-1;

    if (status == 0) RKScheduleForces(@"legacy-AudioSessionSetProperty");
    return status;
}

static OSStatus hook_AudioSessionSetActive(Boolean active) {
    OSStatus status = orig_AudioSessionSetActive ?
        orig_AudioSessionSetActive(active) : (OSStatus)-1;

    if (status == 0 && active) RKScheduleForces(@"legacy-AudioSessionSetActive");
    return status;
}

static OSStatus hook_AudioSessionSetActiveWithFlags(Boolean active, UInt32 flags) {
    OSStatus status = orig_AudioSessionSetActiveWithFlags ?
        orig_AudioSessionSetActiveWithFlags(active, flags) : (OSStatus)-1;

    if (status == 0 && active) RKScheduleForces(@"legacy-AudioSessionSetActiveWithFlags");
    return status;
}

static void RKHookObjCMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !pMSHookMessageEx) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    pMSHookMessageEx(cls, sel, replacement, original);
}

__attribute__((constructor))
static void RKBottomMicRedirectInit(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    gIsTarget = RKIsIPhone4S();
    if (!gIsTarget) {
        [pool drain];
        return;
    }

    void *substrate = dlopen("/Library/MobileSubstrate/MobileSubstrate.dylib",
                             RTLD_LAZY | RTLD_GLOBAL);
    if (!substrate) {
        substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                           RTLD_LAZY | RTLD_GLOBAL);
    }

    pMSHookMessageEx = (MSHookMessageExFn)dlsym(substrate ? substrate : RTLD_DEFAULT,
                                                "MSHookMessageEx");
    pMSHookFunction = (MSHookFunctionFn)dlsym(substrate ? substrate : RTLD_DEFAULT,
                                              "MSHookFunction");

    Class sessionClass = objc_getClass("AVAudioSession");
    if (sessionClass && pMSHookMessageEx) {
        RKHookObjCMethod(sessionClass, @selector(setMode:error:),
                         (IMP)hook_setMode, (IMP *)&orig_setMode);
        RKHookObjCMethod(sessionClass, @selector(setActive:error:),
                         (IMP)hook_setActive, (IMP *)&orig_setActive);
        RKHookObjCMethod(sessionClass, @selector(setActive:withOptions:error:),
                         (IMP)hook_setActiveWithOptions, (IMP *)&orig_setActiveWithOptions);
        RKHookObjCMethod(sessionClass, @selector(setCategory:error:),
                         (IMP)hook_setCategory, (IMP *)&orig_setCategory);
        RKHookObjCMethod(sessionClass, @selector(setCategory:withOptions:error:),
                         (IMP)hook_setCategoryWithOptions, (IMP *)&orig_setCategoryWithOptions);
        RKHookObjCMethod(sessionClass, @selector(setInputDataSource:error:),
                         (IMP)hook_setInputDataSource, (IMP *)&orig_setInputDataSource);
        RKHookObjCMethod(sessionClass, @selector(overrideOutputAudioPort:error:),
                         (IMP)hook_overrideOutputAudioPort, (IMP *)&orig_overrideOutputAudioPort);
    }

    // Also hook the deprecated Audio Session C API because many iOS 6-era apps
    // and system components still use it.
    if (pMSHookFunction) {
        void *audio = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                             RTLD_LAZY | RTLD_GLOBAL);
        void *scope = audio ? audio : RTLD_DEFAULT;

        void *p = dlsym(scope, "AudioSessionSetProperty");
        if (p) pMSHookFunction(p, (void *)&hook_AudioSessionSetProperty,
                               (void **)&orig_AudioSessionSetProperty);

        p = dlsym(scope, "AudioSessionSetActive");
        if (p) pMSHookFunction(p, (void *)&hook_AudioSessionSetActive,
                               (void **)&orig_AudioSessionSetActive);

        p = dlsym(scope, "AudioSessionSetActiveWithFlags");
        if (p) pMSHookFunction(p, (void *)&hook_AudioSessionSetActiveWithFlags,
                               (void **)&orig_AudioSessionSetActiveWithFlags);
    }

    gObserver = [[RKBottomMicObserver alloc] init];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserver:gObserver
           selector:@selector(routeChanged:)
               name:AVAudioSessionRouteChangeNotification
             object:nil];

    [nc addObserver:gObserver
           selector:@selector(mediaReset:)
               name:AVAudioSessionMediaServicesWereResetNotification
             object:nil];

    [nc addObserver:gObserver
           selector:@selector(interruption:)
               name:AVAudioSessionInterruptionNotification
             object:nil];

    RKLog(@"loaded in %@ pid=%d; forcing bottom microphone data source",
          [[NSProcessInfo processInfo] processName], getpid());

    RKScheduleForces(@"initial-load");
    [pool drain];
}
