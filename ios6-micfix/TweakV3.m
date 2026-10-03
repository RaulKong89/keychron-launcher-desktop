#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioSession.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>

typedef void (*MSHookMessageExFn)(Class, SEL, IMP, IMP *);
typedef void (*MSHookFunctionFn)(void *, void *, void **);

static MSHookMessageExFn RKMSHookMessageEx = NULL;
static MSHookFunctionFn RKMSHookFunction = NULL;

static BOOL (*origAVSetMode)(id, SEL, NSString *, NSError **) = NULL;
static NSString *(*origAVMode)(id, SEL) = NULL;
static OSStatus (*origAudioSessionSetProperty)(AudioSessionPropertyID, UInt32, const void *) = NULL;

static BOOL RKIsIPhone4S(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return NO;
    char *machine = (char *)malloc(size);
    if (!machine) return NO;

    BOOL ok = NO;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        ok = (strcmp(machine, "iPhone4,1") == 0);
    }
    free(machine);
    return ok;
}

static BOOL RKIsVideoRecordingMode(NSString *mode) {
    if (!mode) return NO;
    if ([mode isEqualToString:AVAudioSessionModeVideoRecording]) return YES;

    // Defensive fallback in case a private caller passes an equivalent string
    // object instead of the exported constant.
    NSString *lower = [mode lowercaseString];
    return ([lower rangeOfString:@"video"].location != NSNotFound &&
            [lower rangeOfString:@"record"].location != NSNotFound);
}

static BOOL RKHookedSetMode(id self, SEL _cmd, NSString *requestedMode, NSError **error) {
    NSString *effective = requestedMode;

    if (RKIsVideoRecordingMode(requestedMode)) {
        effective = AVAudioSessionModeDefault;
        NSLog(@"[BottomMicRedirect v3] %@ pid=%d: AVAudioSession mode %@ -> %@",
              [[NSProcessInfo processInfo] processName],
              getpid(),
              requestedMode,
              effective);
    }

    return origAVSetMode ? origAVSetMode(self, _cmd, effective, error) : NO;
}

static NSString *RKHookedMode(id self, SEL _cmd) {
    NSString *actual = origAVMode ? origAVMode(self, _cmd) : nil;

    // Do not lie to callers generally. This special-case only protects code
    // that immediately re-applies VideoRecording after observing a mode it set.
    if (RKIsVideoRecordingMode(actual)) {
        return AVAudioSessionModeDefault;
    }
    return actual;
}

static OSStatus RKHookedAudioSessionSetProperty(AudioSessionPropertyID propertyID,
                                                 UInt32 dataSize,
                                                 const void *data) {
    if (propertyID == kAudioSessionProperty_Mode &&
        data &&
        dataSize >= sizeof(UInt32)) {

        UInt32 requested = *(const UInt32 *)data;

        if (requested == kAudioSessionMode_VideoRecording) {
            UInt32 forced = kAudioSessionMode_Default;

            NSLog(@"[BottomMicRedirect v3] %@ pid=%d: legacy mode VideoRecording -> Default",
                  [[NSProcessInfo processInfo] processName], getpid());

            return origAudioSessionSetProperty
                ? origAudioSessionSetProperty(propertyID, sizeof(forced), &forced)
                : (OSStatus)-1;
        }
    }

    return origAudioSessionSetProperty
        ? origAudioSessionSetProperty(propertyID, dataSize, data)
        : (OSStatus)-1;
}

static void RKHookAVAudioSession(void) {
    if (!RKMSHookMessageEx) return;

    Class cls = objc_getClass("AVAudioSession");
    if (!cls) return;

    Method setModeMethod = class_getInstanceMethod(cls, @selector(setMode:error:));
    if (setModeMethod) {
        RKMSHookMessageEx(cls,
                          @selector(setMode:error:),
                          (IMP)RKHookedSetMode,
                          (IMP *)&origAVSetMode);
    }

    Method modeMethod = class_getInstanceMethod(cls, @selector(mode));
    if (modeMethod) {
        RKMSHookMessageEx(cls,
                          @selector(mode),
                          (IMP)RKHookedMode,
                          (IMP *)&origAVMode);
    }
}

static void RKHookLegacyAudioSession(void) {
    if (!RKMSHookFunction) return;

    void *audioToolbox = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                                RTLD_LAZY | RTLD_GLOBAL);
    void *scope = audioToolbox ? audioToolbox : RTLD_DEFAULT;

    void *symbol = dlsym(scope, "AudioSessionSetProperty");
    if (symbol) {
        RKMSHookFunction(symbol,
                         (void *)&RKHookedAudioSessionSetProperty,
                         (void **)&origAudioSessionSetProperty);
    }
}

__attribute__((constructor))
static void RKBottomMicRedirectV3Init(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (!RKIsIPhone4S()) {
        [pool drain];
        return;
    }

    void *substrate = dlopen("/Library/MobileSubstrate/MobileSubstrate.dylib",
                             RTLD_LAZY | RTLD_GLOBAL);
    if (!substrate) {
        substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                           RTLD_LAZY | RTLD_GLOBAL);
    }

    RKMSHookMessageEx = (MSHookMessageExFn)dlsym(substrate ? substrate : RTLD_DEFAULT,
                                                  "MSHookMessageEx");
    RKMSHookFunction = (MSHookFunctionFn)dlsym(substrate ? substrate : RTLD_DEFAULT,
                                                "MSHookFunction");

    RKHookAVAudioSession();
    RKHookLegacyAudioSession();

    // If the process already created a session before our constructor, try to
    // normalize VideoRecording while it is still inactive. The key fix is the
    // interception above: future attempts to select VideoRecording never reach
    // iOS 6's audio server.
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSString *mode = [session mode];

        if (RKIsVideoRecordingMode(mode) && origAVSetMode) {
            NSError *err = nil;
            BOOL ok = origAVSetMode(session,
                                    @selector(setMode:error:),
                                    AVAudioSessionModeDefault,
                                    &err);
            NSLog(@"[BottomMicRedirect v3] initial normalize %@ -> Default: %@ error=%@",
                  mode,
                  ok ? @"YES" : @"NO",
                  err);
        }
    } @catch (NSException *exception) {
        NSLog(@"[BottomMicRedirect v3] startup exception: %@", exception);
    }

    NSLog(@"[BottomMicRedirect v3] loaded in %@ pid=%d",
          [[NSProcessInfo processInfo] processName], getpid());

    [pool drain];
}
