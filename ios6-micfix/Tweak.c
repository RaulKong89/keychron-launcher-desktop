#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/sysctl.h>

typedef int32_t OSStatus;
typedef uint32_t AudioSessionPropertyID;
typedef uint32_t UInt32;
typedef unsigned char Boolean;

typedef OSStatus (*AudioSessionSetPropertyFn)(AudioSessionPropertyID, UInt32, const void *);
typedef OSStatus (*AudioSessionSetActiveFn)(Boolean);
typedef void (*MSHookFunctionFn)(void *, void *, void **);

enum {
    kAudioSessionProperty_Mode = 0x6d6f6465U,
    kAudioSessionMode_Default = 0x64666c74U,
    kAudioSessionMode_VoiceChat = 0x76636374U,
    kAudioSessionMode_VideoRecording = 0x76726364U,
    kAudioSessionMode_GameChat = 0x676d6374U
};

static AudioSessionSetPropertyFn origSetProperty = NULL;
static AudioSessionSetActiveFn origSetActive = NULL;

static int is_iPhone4S(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    char *machine = (char *)malloc(size);
    if (!machine) return 0;
    int ok = 0;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        ok = strcmp(machine, "iPhone4,1") == 0;
    }
    free(machine);
    return ok;
}

static int shouldForceBottomMode(UInt32 mode) {
    return mode == kAudioSessionMode_VideoRecording ||
           mode == kAudioSessionMode_VoiceChat ||
           mode == kAudioSessionMode_GameChat;
}

static OSStatus hookSetProperty(AudioSessionPropertyID property,
                                UInt32 size,
                                const void *data) {
    if (origSetProperty &&
        property == kAudioSessionProperty_Mode &&
        data && size >= sizeof(UInt32)) {
        UInt32 requested = *(const UInt32 *)data;
        if (shouldForceBottomMode(requested)) {
            UInt32 bottomMode = kAudioSessionMode_Default;
            return origSetProperty(property, sizeof(bottomMode), &bottomMode);
        }
    }
    return origSetProperty ? origSetProperty(property, size, data) : (OSStatus)-1;
}

static OSStatus hookSetActive(Boolean active) {
    if (active && origSetProperty) {
        UInt32 bottomMode = kAudioSessionMode_Default;
        origSetProperty(kAudioSessionProperty_Mode, sizeof(bottomMode), &bottomMode);
    }
    return origSetActive ? origSetActive(active) : (OSStatus)-1;
}

__attribute__((constructor))
static void BottomMicRedirectInit(void) {
    if (!is_iPhone4S()) return;

    void *substrate = dlopen("/Library/MobileSubstrate/MobileSubstrate.dylib",
                             RTLD_LAZY | RTLD_GLOBAL);
    if (!substrate) {
        substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                           RTLD_LAZY | RTLD_GLOBAL);
    }

    MSHookFunctionFn MSHookFunction =
        (MSHookFunctionFn)dlsym(substrate ? substrate : RTLD_DEFAULT, "MSHookFunction");
    if (!MSHookFunction) return;

    void *audioToolbox = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                                RTLD_LAZY | RTLD_GLOBAL);
    void *scope = audioToolbox ? audioToolbox : RTLD_DEFAULT;

    void *pSetProperty = dlsym(scope, "AudioSessionSetProperty");
    void *pSetActive = dlsym(scope, "AudioSessionSetActive");

    if (pSetProperty) {
        MSHookFunction(pSetProperty, (void *)&hookSetProperty, (void **)&origSetProperty);
    }
    if (pSetActive) {
        MSHookFunction(pSetActive, (void *)&hookSetActive, (void **)&origSetActive);
    }
}
