#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/mman.h>
#import <signal.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <math.h>
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#define fm NSFileManager.defaultManager

extern char **environ;

// Validate contiguous virtual memory space
BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

// Load default environment variables
void init_loadDefaultEnv() {
    setenv("LD_LIBRARY_PATH", "", 1);
    setenv("LIBGL_NOINTOVLHACK", "1", 1);
    setenv("LIBGL_NORMALIZE", "1", 1);
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

// Load custom environment variables from profile
void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) continue;
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

// Load custom JVM flags from profile
void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (!jvmargs) return;
    jvmargs = [[@" " stringByAppendingString:[jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]] copy];
    
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;
        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;
    }
}

// Main JVM launch
int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    BOOL requiresTXMWorkaround = DeviceRequiresTXMWorkaround();
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresTXMWorkaround) {
        void *result = JIT26CreateRegionLegacy(getpagesize());
        if ((uintptr_t)result != 0x690000E0) { // fix cast warning
            munmap(result, getpagesize());
            [fm copyItemAtPath:[NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"]
                          toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")]
                           error:nil];
            showDialog(@"Error", @"Support for legacy script removed. Switch to Universal JIT script in Amethyst Documents.");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"] encoding:NSUTF8StringEncoding error:nil]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
#if TARGET_OS_IOS
        // prevent EXC_BAD_ACCESS (conditional compilation)
        // task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
#endif
    } else {
        init_bypassDyldLibValidation();
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    // Determine game directory & JRE
    NSString *gameDir;
    NSString *defaultJRETag;
    BOOL launchJar = NO;
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0 && minVersion <= preferredJavaVersion) minVersion = preferredJavaVersion;
        defaultJRETag = (minVersion <= 8) ? @"1_16_5_older" : @"1_17_newer";
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]].stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
    }

    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);
    if (!javaHome) {
        showDialog(@"Error", [NSString stringWithFormat:@"Missing Java runtime for %@ ≥ %d", launchJar ? launchTarget : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);

    // RAM allocation
    int allocmem = getPrefBool(@"java.auto_ram") ? roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * (getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25))
                                                : getPrefInt(@"java.allocated_memory");
    if (!validateVirtualMemorySpace(allocmem)) {
        showDialog(@"Error", @"Insufficient contiguous virtual memory space. Lower allocation and retry.");
        return 1;
    }

    // --- Prepare JVM arguments ---
    int margc = -1;
    const char *margv[1000];

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    if (!launchJar) margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;

    init_loadCustomJvmFlags(&margc, (const char **)margv);

    NSString *classpath = [NSString stringWithFormat:@"%@/*", [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"libs"]];
    if (launchJar) classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;
    margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";

    if (launchJar) {
        margv[++margc] = "-jar";
    } else {
        margv[++margc] = username.UTF8String;
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        margv[++margc] = [launchTarget[@"id"] UTF8String];
    } else {
        margv[++margc] = [launchTarget UTF8String];
    }

    // Load JLI library
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome];
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome];
    setenv("INTERNAL_JLI_PATH", ([fm fileExistsAtPath:libjlipath8] ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);
    if (!libjli) {
        showDialog(@"Error", @(dlerror()));
        return 1;
    }

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
    if (!pJLI_Launch) return -2;

    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    tmpRootVC = nil;

    return pJLI_Launch(++margc, margv,
                       0, NULL,
                       0, NULL,
                       "1.8.0-internal",
                       "1.8",
                       "java", "openjdk",
                       JNI_FALSE,
                       JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
