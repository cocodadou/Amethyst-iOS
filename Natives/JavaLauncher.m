#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/exc.h>

#include "utils.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager

extern char **environ;

BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

void init_loadDefaultEnv() {
    setenv("LD_LIBRARY_PATH", "", 1);
    setenv("LIBGL_NOINTOVLHACK", "1", 1);
    setenv("LIBGL_NORMALIZE", "1", 1);
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    BOOL requiresTXMWorkaround = DeviceRequiresTXMWorkaround();
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresTXMWorkaround) {
        void *result = JIT26CreateRegionLegacy(getpagesize());
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"]
                                                  toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")]
                                                   error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script.");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }

        NSError *error = nil;
        NSString *jitScriptPath = [[NSBundle mainBundle] pathForResource:@"UniversalJIT26Extension" ofType:@"js"];
        NSString *jitScript = [NSString stringWithContentsOfFile:jitScriptPath encoding:NSUTF8StringEncoding error:&error];
        if (jitScript && !error) {
            JIT26SendJITScript(jitScript);
        } else {
            NSLog(@"[JavaLauncher] Failed to load JIT script: %@", error);
        }

        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);

#if TARGET_OS_IOS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
#endif
    }

    if (!requiresTXMWorkaround || jit26AlwaysAttached) {
        init_bypassDyldLibValidation();
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    // --- Remaining code unchanged ---
    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0 && minVersion > preferredJavaVersion) {
            NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
        } else if (preferredJavaVersion > 0) {
            minVersion = preferredJavaVersion;
        }

        defaultJRETag = (minVersion <= 8) ? @"1_16_5_older" : @"1_17_newer";

        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSLog(@"[JavaLauncher] RENDERER is set to %@", renderer);
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);

        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@", getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"), [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]].stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
    }

    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil), isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    // --- Memory allocation and JVM arguments setup unchanged ---
    // Continue with remaining code as in your original file

    return pJLI_Launch(++margc, margv,
                       0, NULL,
                       0, NULL,
                       "1.8.0-internal",
                       "1.8",
                       "java", "openjdk",
                       JNI_FALSE,
                       JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
