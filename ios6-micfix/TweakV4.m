#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioSession.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

typedef void (*MSHookMessageExFn)(Class, SEL, IMP, IMP *);
typedef void (*MSHookFunctionFn)(void *, void *, void **);

static MSHookMessageExFn RKMSHookMessageEx = NULL;
static MSHookFunctionFn RKMSHookFunction = NULL;

static BOOL (*origSetMode)(id,SEL,NSString *,NSError **) = NULL;
static BOOL (*origSetActive)(id,SEL,BOOL,NSError **) = NULL;
static BOOL (*origSetActiveOptions)(id,SEL,BOOL,NSUInteger,NSError **) = NULL;
static BOOL (*origSetInputDataSource)(id,SEL,id,NSError **) = NULL;
static void (*origCaptureStartRunning)(id,SEL) = NULL;

static OSStatus (*origAudioSessionSetProperty)(AudioSessionPropertyID,UInt32,const void *) = NULL;
static OSStatus (*origAudioSessionSetActive)(Boolean) = NULL;
static OSStatus (*origAudioSessionSetActiveWithFlags)(Boolean,UInt32) = NULL;

static volatile int gApplying = 0;
static const unsigned long long kBottomMicID = 1835216945ULL;
static const char *kLogPath = "/var/mobile/Library/Logs/BottomMicRedirect.log";

@interface AVAudioSession (RKPrivateIOS6)
- (id)inputDataSources;
- (id)inputDataSource;
- (BOOL)setInputDataSource:(id)source error:(NSError **)error;
@end

static void RKLog(const char *fmt, ...) {
    char line[2048];
    char body[1600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    NSString *proc = [[NSProcessInfo processInfo] processName];
    snprintf(line, sizeof(line), "[BottomMicRedirect v4 pid=%d %s] %s\n",
             getpid(), proc ? [proc UTF8String] : "?", body);

    int fd = open(kLogPath, O_WRONLY|O_CREAT|O_APPEND, 0666);
    if (fd >= 0) {
        write(fd, line, strlen(line));
        close(fd);
        chmod(kLogPath, 0666);
    }
    NSLog(@"%s", line);
}

static BOOL RKIsIPhone4S(void) {
    size_t n = 0;
    if (sysctlbyname("hw.machine", NULL, &n, NULL, 0) != 0 || !n) return NO;
    char *buf = malloc(n);
    if (!buf) return NO;
    BOOL ok = NO;
    if (sysctlbyname("hw.machine", buf, &n, NULL, 0) == 0)
        ok = strcmp(buf, "iPhone4,1") == 0;
    free(buf);
    return ok;
}

static BOOL RKIsVideoRecordingMode(NSString *mode) {
    if (!mode) return NO;
    if ([mode isEqualToString:AVAudioSessionModeVideoRecording]) return YES;
    NSString *s = [mode lowercaseString];
    return ([s rangeOfString:@"video"].location != NSNotFound &&
            [s rangeOfString:@"record"].location != NSNotFound);
}

static id RKBottomDataSource(AVAudioSession *session) {
    if (!session || ![session respondsToSelector:@selector(inputDataSources)]) return nil;

    NSArray *sources = nil;
    @try { sources = [session inputDataSources]; }
    @catch (NSException *e) { RKLog("inputDataSources exception: %s", [[e description] UTF8String]); return nil; }

    RKLog("inputDataSources count=%lu desc=%s",
          (unsigned long)[sources count], sources ? [[sources description] UTF8String] : "(nil)");

    for (id src in sources) {
        NSNumber *sid = nil;
        NSString *name = nil;
        @try {
            if ([src respondsToSelector:@selector(dataSourceID)]) sid = [src dataSourceID];
            if ([src respondsToSelector:@selector(dataSourceName)]) name = [src dataSourceName];
        } @catch (...) {}

        RKLog("source name=%s id=%llu",
              name ? [name UTF8String] : "(nil)",
              sid ? [sid unsignedLongLongValue] : 0ULL);

        if (sid && [sid unsignedLongLongValue] == kBottomMicID) return src;
        if (name && [name caseInsensitiveCompare:@"Bottom"] == NSOrderedSame) return src;
    }
    return nil;
}

static void RKForceBottom(const char *reason) {
    if (gApplying) return;
    gApplying = 1;

    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSString *mode = nil;
        @try { mode = [s mode]; } @catch (...) {}
        RKLog("force reason=%s currentMode=%s",
              reason, mode ? [mode UTF8String] : "(nil)");

        if (RKIsVideoRecordingMode(mode) && origSetMode) {
            NSError *err = nil;
            BOOL ok = origSetMode(s, @selector(setMode:error:), AVAudioSessionModeDefault, &err);
            RKLog("normalize VideoRecording->Default ok=%d err=%s",
                  ok, err ? [[err description] UTF8String] : "(nil)");
        }

        id bottom = RKBottomDataSource(s);
        if (bottom && origSetInputDataSource) {
            NSError *err = nil;
            BOOL ok = origSetInputDataSource(s, @selector(setInputDataSource:error:), bottom, &err);
            RKLog("setInputDataSource Bottom ok=%d err=%s",
                  ok, err ? [[err description] UTF8String] : "(nil)");
        } else {
            RKLog("bottom source unavailable or setter not hooked");
        }
    } @catch (NSException *e) {
        RKLog("force exception: %s", [[e description] UTF8String]);
    }

    gApplying = 0;
}

static void RKDelayed(void *ctx) {
    NSAutoreleasePool *p = [[NSAutoreleasePool alloc] init];
    RKForceBottom((const char *)ctx);
    [p drain];
}

static void RKScheduleAll(void) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), "delay10", RKDelayed);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), "delay100", RKDelayed);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), "delay500", RKDelayed);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), "delay1500", RKDelayed);
}

static BOOL hookSetMode(id self, SEL cmd, NSString *requested, NSError **error) {
    NSString *effective = requested;
    if (RKIsVideoRecordingMode(requested)) {
        effective = AVAudioSessionModeDefault;
        RKLog("BLOCK setMode VideoRecording -> Default");
    } else {
        RKLog("setMode request=%s", requested ? [requested UTF8String] : "(nil)");
    }

    BOOL ok = origSetMode ? origSetMode(self, cmd, effective, error) : NO;
    if (ok) RKScheduleAll();
    return ok;
}

static BOOL hookSetActive(id self, SEL cmd, BOOL active, NSError **error) {
    BOOL ok = origSetActive ? origSetActive(self, cmd, active, error) : NO;
    RKLog("setActive %d -> %d", active, ok);
    if (active && ok) { RKForceBottom("setActive"); RKScheduleAll(); }
    return ok;
}

static BOOL hookSetActiveOptions(id self, SEL cmd, BOOL active, NSUInteger opts, NSError **error) {
    BOOL ok = origSetActiveOptions ? origSetActiveOptions(self, cmd, active, opts, error) : NO;
    RKLog("setActive options active=%d opts=%lu -> %d", active, (unsigned long)opts, ok);
    if (active && ok) { RKForceBottom("setActiveOptions"); RKScheduleAll(); }
    return ok;
}

static BOOL hookSetInputDataSource(id self, SEL cmd, id requested, NSError **error) {
    if (gApplying)
        return origSetInputDataSource ? origSetInputDataSource(self, cmd, requested, error) : NO;

    id bottom = RKBottomDataSource((AVAudioSession *)self);
    id effective = bottom ? bottom : requested;

    RKLog("setInputDataSource requested=%s effective=%s",
          requested ? [[requested description] UTF8String] : "(nil)",
          effective ? [[effective description] UTF8String] : "(nil)");

    return origSetInputDataSource ? origSetInputDataSource(self, cmd, effective, error) : NO;
}

static void hookCaptureStartRunning(id self, SEL cmd) {
    RKLog("AVCaptureSession startRunning ENTER");
    RKForceBottom("capture-before");
    if (origCaptureStartRunning) origCaptureStartRunning(self, cmd);
    RKLog("AVCaptureSession startRunning EXIT");
    RKForceBottom("capture-after");
    RKScheduleAll();
}

static OSStatus hookAudioSessionSetProperty(AudioSessionPropertyID prop, UInt32 size, const void *data) {
    if (prop == kAudioSessionProperty_Mode && data && size >= sizeof(UInt32)) {
        UInt32 mode = *(const UInt32 *)data;
        RKLog("legacy SetProperty MODE=0x%08lx", (unsigned long)mode);
        if (mode == kAudioSessionMode_VideoRecording) {
            UInt32 forced = kAudioSessionMode_Default;
            RKLog("BLOCK legacy VideoRecording -> Default");
            OSStatus st = origAudioSessionSetProperty ?
                origAudioSessionSetProperty(prop, sizeof(forced), &forced) : -1;
            if (st == 0) RKScheduleAll();
            return st;
        }
    }
    return origAudioSessionSetProperty ? origAudioSessionSetProperty(prop, size, data) : -1;
}

static OSStatus hookAudioSessionSetActive(Boolean active) {
    OSStatus st = origAudioSessionSetActive ? origAudioSessionSetActive(active) : -1;
    RKLog("legacy SetActive %d status=%ld", active, (long)st);
    if (active && st == 0) { RKForceBottom("legacy-active"); RKScheduleAll(); }
    return st;
}

static OSStatus hookAudioSessionSetActiveWithFlags(Boolean active, UInt32 flags) {
    OSStatus st = origAudioSessionSetActiveWithFlags ? origAudioSessionSetActiveWithFlags(active, flags) : -1;
    RKLog("legacy SetActiveWithFlags %d flags=0x%lx status=%ld",
          active, (unsigned long)flags, (long)st);
    if (active && st == 0) { RKForceBottom("legacy-active-flags"); RKScheduleAll(); }
    return st;
}

static void RKHookObjC(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !RKMSHookMessageEx || !class_getInstanceMethod(cls, sel)) return;
    RKMSHookMessageEx(cls, sel, replacement, original);
    RKLog("hooked ObjC %s %s", class_getName(cls), sel_getName(sel));
}

__attribute__((constructor))
static void RKInit(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (!RKIsIPhone4S()) { [pool drain]; return; }

    RKLog("LOADED from scratch");

    void *sub = dlopen("/Library/MobileSubstrate/MobileSubstrate.dylib", RTLD_LAZY|RTLD_GLOBAL);
    if (!sub) sub = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_LAZY|RTLD_GLOBAL);

    RKMSHookMessageEx = (MSHookMessageExFn)dlsym(sub ? sub : RTLD_DEFAULT, "MSHookMessageEx");
    RKMSHookFunction = (MSHookFunctionFn)dlsym(sub ? sub : RTLD_DEFAULT, "MSHookFunction");

    RKLog("substrate=%p MSHookMessageEx=%p MSHookFunction=%p", sub, RKMSHookMessageEx, RKMSHookFunction);

    Class av = objc_getClass("AVAudioSession");
    RKHookObjC(av, @selector(setMode:error:), (IMP)hookSetMode, (IMP *)&origSetMode);
    RKHookObjC(av, @selector(setActive:error:), (IMP)hookSetActive, (IMP *)&origSetActive);
    RKHookObjC(av, @selector(setActive:withOptions:error:), (IMP)hookSetActiveOptions, (IMP *)&origSetActiveOptions);
    RKHookObjC(av, @selector(setInputDataSource:error:), (IMP)hookSetInputDataSource, (IMP *)&origSetInputDataSource);

    Class cap = objc_getClass("AVCaptureSession");
    RKHookObjC(cap, @selector(startRunning), (IMP)hookCaptureStartRunning, (IMP *)&origCaptureStartRunning);

    if (RKMSHookFunction) {
        void *at = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY|RTLD_GLOBAL);
        void *scope = at ? at : RTLD_DEFAULT;
        void *p = dlsym(scope, "AudioSessionSetProperty");
        if (p) RKMSHookFunction(p, (void *)&hookAudioSessionSetProperty, (void **)&origAudioSessionSetProperty);
        p = dlsym(scope, "AudioSessionSetActive");
        if (p) RKMSHookFunction(p, (void *)&hookAudioSessionSetActive, (void **)&origAudioSessionSetActive);
        p = dlsym(scope, "AudioSessionSetActiveWithFlags");
        if (p) RKMSHookFunction(p, (void *)&hookAudioSessionSetActiveWithFlags, (void **)&origAudioSessionSetActiveWithFlags);
    }

    RKForceBottom("constructor");
    RKScheduleAll();
    [pool drain];
}
