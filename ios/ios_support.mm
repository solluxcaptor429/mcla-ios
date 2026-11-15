// What only the iOS app needs, ahead of everything else in the process.
//
// Runs from a constructor: the runtime's own static objects and SDL's
// UIApplicationMain come later, so a start that fails early still leaves a
// trace in Documents (the Files app shows it under "On My iPhone > MCLA").

#import <Foundation/Foundation.h>

#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <iterator>

#include <rex/cvar.h>

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

    // The fork's shader pack: the game looks for shaderpack/545407F8.shaderpack
    // beside its settings (Documents here) and imports what its shader storage
    // lacks, so the pipelines are built before they are drawn with. Without it
    // every object is missing until its pipeline has compiled on the fly.
    NSFileManager* files = [NSFileManager defaultManager];
    NSString* pack_name = @"shaderpack/545407F8.shaderpack";
    NSString* bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:pack_name];
    NSString* placed = [documents stringByAppendingPathComponent:pack_name];
    if ([files fileExistsAtPath:bundled]) {
      unsigned long long bundled_size = [[files attributesOfItemAtPath:bundled error:nil] fileSize];
      unsigned long long placed_size = [[files attributesOfItemAtPath:placed error:nil] fileSize];
      if (bundled_size != placed_size) {
        [files createDirectoryAtPath:[placed stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        [files removeItemAtPath:placed error:nil];
        NSError* error = nil;
        BOOL copied = [files copyItemAtPath:bundled toPath:placed error:&error];
        printf("[mcla-ios] shader pack %s Documents (%llu bytes)%s%s\n", copied ? "copied to" : "NOT copied to",
               bundled_size, copied ? "" : ": ", copied ? "" : error.localizedDescription.UTF8String);
      }
    } else {
      printf("[mcla-ios] no shader pack in the app bundle\n");
    }

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

// "iPad16,3" -> 16; 0 when it isn't a model of that kind.
int ModelGeneration(const char* machine, const char* kind) {
  const size_t length = strlen(kind);
  if (strncmp(machine, kind, length) != 0) {
    return 0;
  }
  return atoi(machine + length);
}

}  // namespace

// Graphics defaults by device, set before the settings are read: what the
// player sets in the pause menu or in Documents/mcla.toml still wins, and these
// are never written there as if chosen.
//
//   iPad Pro with M4 or later (iPad16,3-6 and newer, 8 GB or more): the
//   console's 720p drawn at 2x (1440p, close to the 13" panel's 2064 rows)
//   and the game's 60 FPS cap; the M4's CPU and 10-core GPU are a Mac's.
//   iPhone (the Pro Max, the foldable): the console's 720p and the game's own
//   30 FPS cap, the GPU's headroom left to the EDRAM emulation. The screen's
//   shape is the game's own business (mcla_aspect_ratio auto: wider than 16:9
//   widens the view, narrower, as the foldable's and the iPad's 4:3 are,
//   keeps 16:9 with bars).
extern "C" void MclaIosApplyDeviceDefaults(void) {
  char machine[64] = "";
  size_t machine_size = sizeof(machine);
  sysctlbyname("hw.machine", machine, &machine_size, nullptr, 0);
  uint64_t physical = 0;
  size_t physical_size = sizeof(physical);
  sysctlbyname("hw.memsize", &physical, &physical_size, nullptr, 0);

  const int ipad = ModelGeneration(machine, "iPad");
  // iPad16,1/2 is the iPad mini with the A17 Pro: a phone's GPU.
  const bool ipad_mini_a17 = strcmp(machine, "iPad16,1") == 0 || strcmp(machine, "iPad16,2") == 0;
  const bool large = ipad >= 16 && !ipad_mini_a17 && (physical >> 30) >= 7;

  struct Default {
    const char* name;
    const char* value;
  };
  const Default large_defaults[] = {{"resolution_scale", "2"}, {"mcla_fps", "60"}};
  const Default small_defaults[] = {{"resolution_scale", "1"}};
  const Default* defaults = large ? large_defaults : small_defaults;
  const size_t count = large ? std::size(large_defaults) : std::size(small_defaults);

  printf("[mcla-ios] device class: %s (%s)\n", large ? "M-class iPad" : "phone-class", machine);
  for (size_t i = 0; i < count; ++i) {
    const bool taken = rex::cvar::SetDefaultValue(defaults[i].name, defaults[i].value);
    printf("[mcla-ios]   %s = %s%s\n", defaults[i].name, defaults[i].value, taken ? "" : " (not taken)");
  }
}
