#include <substrate.h>
#include <AudioToolbox/AudioSession.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <string.h>
#include <stdlib.h>

typedef OSStatus (*AudioSessionSetPropertyFn)(AudioSessionPropertyID, UInt32, const void *);
typedef OSStatus (*AudioSessionSetActiveFn)(Boolean);

static AudioSessionSetPropertyFn orig_AudioSessionSetProperty = NULL;
static AudioSessionSetActiveFn orig_AudioSessionSetActive = NULL;

static int is_iPhone4S(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    char *machine = (char *)malloc(size);
    if (!machine) return 0;
    int ok = 0;
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        ok = (strcmp(machine, "iPhone4,1") == 0);
    }
    free(machine);
    return ok;
}

static int modeMaySelectUpperMic(UInt32 mode) {
    return mode == kAudioSessionMode_VideoRecording ||
           mode == kAudioSessionMode_VoiceChat ||
           mode == kAudioSessionMode_GameChat;
}

static OSStatus replaced_AudioSessionSetProperty(AudioSessionPropertyID inID,
                                                  UInt32 inDataSize,
                                                  const void *inData) {
    if (orig_AudioSessionSetProperty &&
        inID == kAudioSessionProperty_Mode &&
        inData && inDataSize >= sizeof(UInt32)) {
        UInt32 requested = *(const UInt32 *)inData;
        if (modeMaySelectUpperMic(requested)) {
            UInt32 forced = kAudioSessionMode_Default;
            return orig_AudioSessionSetProperty(inID, sizeof(forced), &forced);
        }
    }
    return orig_AudioSessionSetProperty ?
        orig_AudioSessionSetProperty(inID, inDataSize, inData) : -1;
}

static OSStatus replaced_AudioSessionSetActive(Boolean active) {
    if (active && orig_AudioSessionSetProperty) {
        UInt32 forced = kAudioSessionMode_Default;
        orig_AudioSessionSetProperty(kAudioSessionProperty_Mode, sizeof(forced), &forced);
    }
    return orig_AudioSessionSetActive ? orig_AudioSessionSetActive(active) : -1;
}

__attribute__((constructor))
static void BottomMicRedirectInit(void) {
    if (!is_iPhone4S()) return;

    void *audioToolbox = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                               RTLD_LAZY | RTLD_GLOBAL);
    void *setProperty = dlsym(audioToolbox ? audioToolbox : RTLD_DEFAULT,
                              "AudioSessionSetProperty");
    void *setActive = dlsym(audioToolbox ? audioToolbox : RTLD_DEFAULT,
                            "AudioSessionSetActive");

    if (setProperty) {
        MSHookFunction(setProperty,
                       (void *)&replaced_AudioSessionSetProperty,
                       (void **)&orig_AudioSessionSetProperty);
    }
    if (setActive) {
        MSHookFunction(setActive,
                       (void *)&replaced_AudioSessionSetActive,
                       (void **)&orig_AudioSessionSetActive);
    }
}
