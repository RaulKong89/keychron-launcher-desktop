#include <CoreFoundation/CoreFoundation.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CFStringRef Domain(void) { return CFSTR("com.apple.audio.virtualaudio"); }
static CFStringRef Key(void) { return CFSTR("BuiltInMicSelection"); }

static int is_iPhone4S(void) {
    size_t n = 0;
    if (sysctlbyname("hw.machine", NULL, &n, NULL, 0) != 0 || n == 0) return 0;
    char *buf = (char *)malloc(n);
    if (!buf) return 0;
    int ok = 0;
    if (sysctlbyname("hw.machine", buf, &n, NULL, 0) == 0)
        ok = (strcmp(buf, "iPhone4,1") == 0);
    free(buf);
    return ok;
}

static void print_value(const char *label, CFPropertyListRef v) {
    if (!v) {
        printf("%s: <absent>\n", label);
        return;
    }
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int x = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &x);
        printf("%s: %d\n", label, x);
    } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
        char b[256] = {0};
        CFStringGetCString((CFStringRef)v, b, sizeof(b), kCFStringEncodingUTF8);
        printf("%s: string '%s'\n", label, b);
    } else if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        printf("%s: bool %d\n", label, CFBooleanGetValue((CFBooleanRef)v));
    } else {
        printf("%s: type-id %lu\n", label, (unsigned long)CFGetTypeID(v));
    }
}

static int set_for_current_user(int clear) {
    CFPropertyListRef value = NULL;
    CFNumberRef num = NULL;
    int one = 1;

    if (!clear) {
        num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &one);
        value = num;
    }

    CFPreferencesSetAppValue(Key(), value, Domain());
    Boolean a = CFPreferencesAppSynchronize(Domain());

    CFPreferencesSetValue(Key(), value, Domain(),
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    Boolean b = CFPreferencesSynchronize(Domain(),
                                         kCFPreferencesCurrentUser,
                                         kCFPreferencesAnyHost);

    if (num) CFRelease(num);
    return (a && b) ? 0 : 1;
}

static int set_system_scope(int clear) {
    CFPropertyListRef value = NULL;
    CFNumberRef num = NULL;
    int one = 1;

    if (!clear) {
        num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &one);
        value = num;
    }

    CFPreferencesSetValue(Key(), value, Domain(),
                          kCFPreferencesAnyUser,
                          kCFPreferencesAnyHost);
    Boolean a = CFPreferencesSynchronize(Domain(),
                                         kCFPreferencesAnyUser,
                                         kCFPreferencesAnyHost);

    CFPreferencesSetValue(Key(), value, Domain(),
                          kCFPreferencesAnyUser,
                          kCFPreferencesCurrentHost);
    Boolean b = CFPreferencesSynchronize(Domain(),
                                         kCFPreferencesAnyUser,
                                         kCFPreferencesCurrentHost);

    if (num) CFRelease(num);
    return (a || b) ? 0 : 1;
}

static int set_mobile_scope(int clear) {
    pid_t p = fork();
    if (p < 0) return 1;

    if (p == 0) {
        setenv("HOME", "/var/mobile", 1);
        if (setgid(501) != 0 || setuid(501) != 0) _exit(20);
        int r = set_for_current_user(clear);
        _exit(r ? 21 : 0);
    }

    int st = 0;
    if (waitpid(p, &st, 0) < 0) return 1;
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) return 1;
    return 0;
}

static void status(void) {
    printf("BottomMicRedirect HAL v5 status\n");
    printf("machine: %s\n", is_iPhone4S() ? "iPhone4,1 (iPhone 4S / N94)" : "NOT iPhone4,1");

    CFPropertyListRef v = CFPreferencesCopyAppValue(Key(), Domain());
    print_value("CFPreferencesCopyAppValue", v);
    if (v) CFRelease(v);

    v = CFPreferencesCopyValue(Key(), Domain(),
                               kCFPreferencesAnyUser,
                               kCFPreferencesAnyHost);
    print_value("AnyUser/AnyHost", v);
    if (v) CFRelease(v);

    v = CFPreferencesCopyValue(Key(), Domain(),
                               kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost);
    print_value("CurrentUser/AnyHost", v);
    if (v) CFRelease(v);

    printf("Expected forced value: 1 (bit 0 = bottom/primary mic on N94 iOS 6.1.3)\n");
}

int main(int argc, char **argv) {
    if (!is_iPhone4S()) {
        fprintf(stderr, "BottomMicRedirect v5: refusing to alter audio defaults on non-iPhone4,1 hardware.\n");
        return 2;
    }

    if (argc >= 2 && strcmp(argv[1], "status") == 0) {
        status();
        return 0;
    }

    int clear = (argc >= 2 && strcmp(argv[1], "clear") == 0);

    int r_root = set_for_current_user(clear);
    int r_system = set_system_scope(clear);
    int r_mobile = set_mobile_scope(clear);

    printf("BottomMicRedirect v5: %s BuiltInMicSelection %s\n",
           clear ? "cleared" : "forced",
           clear ? "" : "= 1 (bottom mic only)");
    printf("sync root=%s system=%s mobile=%s\n",
           r_root ? "FAIL" : "OK",
           r_system ? "FAIL" : "OK",
           r_mobile ? "FAIL" : "OK");

    status();

    // At least one persistent preference scope must succeed.
    return (r_root && r_system && r_mobile) ? 3 : 0;
}
