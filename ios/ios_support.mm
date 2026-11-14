// What only the iOS app needs, ahead of everything else in the process.
//
// Runs from a constructor: the runtime's own static objects and SDL's
// UIApplicationMain come later, so a start that fails early still leaves a
// trace in Documents (the Files app shows it under "On My iPhone > MCLA").

#import <Foundation/Foundation.h>

#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

namespace {

__attribute__((constructor(101))) void MclaIosEarlyInit() {
  @autoreleasepool {
    NSString* documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // stdout and stderr have nowhere to go in an app: keep them, and the run
    // before this one (a crash is usually looked at after the next start).
    NSString* console = [documents stringByAppendingPathComponent:@"mcla-console.txt"];
    NSString* previous = [documents stringByAppendingPathComponent:@"mcla-console.previous.txt"];
    rename(console.fileSystemRepresentation, previous.fileSystemRepresentation);
    if (freopen(console.fileSystemRepresentation, "w", stdout)) {
      setvbuf(stdout, nullptr, _IOLBF, 0);
      dup2(fileno(stdout), STDERR_FILENO);
      setvbuf(stderr, nullptr, _IONBF, 0);
    }

    // Relative paths (a log file named in mcla.toml) land beside the settings.
    chdir(documents.fileSystemRepresentation);

    // Sound with the ring switch off, as a game console would play it; no home
    // indicator over the picture until the screen is touched.
    setenv("SDL_AUDIO_CATEGORY", "playback", 0);
    setenv("SDL_IOS_HIDE_HOME_INDICATOR", "2", 0);

    uint64_t physical = 0;
    size_t physical_size = sizeof(physical);
    sysctlbyname("hw.memsize", &physical, &physical_size, nullptr, 0);
    char machine[64] = "";
    size_t machine_size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &machine_size, nullptr, 0);
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    printf("[mcla-ios] %s, iOS %ld.%ld.%ld, %llu MiB physical, %llu MiB available to this process\n",
           machine, (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion,
           (unsigned long long)(physical >> 20),
           (unsigned long long)(os_proc_available_memory() >> 20));
    printf("[mcla-ios] documents: %s\n", documents.fileSystemRepresentation);
    printf("[mcla-ios] game files are looked for in Documents/game (default.xex and the .rpf files)\n");
  }
}

}  // namespace
