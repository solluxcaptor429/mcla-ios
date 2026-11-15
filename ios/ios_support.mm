// What only the iOS app needs, ahead of everything else in the process.
//
// Runs from a constructor: the runtime's own static objects and SDL's
// UIApplicationMain come later, so a start that fails early still leaves a
// trace in Documents (the Files app shows it under "On My iPhone > MCLA").

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include <iterator>

#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>

#include <algorithm>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include <rex/cvar.h>
#include <rex/ui/app_background.h>

extern "C" bool MclaIosMetalStatsInstall(void);                      // ios_metal_stats.mm
extern "C" bool MclaIosMetalStatsRead(unsigned long long* counts);  // ios_metal_stats.mm
extern "C" void MclaIosStartTouchControls(void);                    // ios_touch.mm

// The Vulkan command processor's own counters (rexgpu-xenos, linked in):
// {submissions, microseconds in them, blocking fence waits, microseconds in
// those}, and the draws the game issued and the host made of them.
namespace rex::graphics::vulkan {
void SubmissionCounters(uint64_t out[4]);
uint64_t DrawCounter();
uint64_t HostDrawCounter();
}  // namespace rex::graphics::vulkan

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

    // Documents/mcla-env.txt: NAME=value lines set as environment variables
    // before anything reads them (MoltenVK's MVK_CONFIG_*, SDL hints, the
    // MCLA_* switches below): settings to try without another build.
    NSString* env_file = [documents stringByAppendingPathComponent:@"mcla-env.txt"];
    NSString* env_text = [NSString stringWithContentsOfFile:env_file encoding:NSUTF8StringEncoding error:nil];
    for (NSString* raw in [env_text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
      NSString* line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      const NSRange equals = [line rangeOfString:@"="];
      if (line.length == 0 || [line hasPrefix:@"#"] || equals.location == NSNotFound) {
        continue;
      }
      NSString* name = [line substringToIndex:equals.location];
      NSString* value = [line substringFromIndex:equals.location + 1];
      setenv(name.UTF8String, value.UTF8String, 1);
      printf("[mcla-ios] mcla-env.txt: %s=%s\n", name.UTF8String, value.UTF8String);
    }

    // A test run's own user folder (MCLA_USER_ROOT), made from the player's
    // the first time: the saves and the shader storage, never written back.
    if (const char* user_root = getenv("MCLA_USER_ROOT"); user_root && user_root[0]) {
      NSString* support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
      NSString* root = [support stringByAppendingPathComponent:@(user_root)];
      NSString* copy = [root stringByAppendingPathComponent:@"mcla"];
      NSFileManager* manager = [NSFileManager defaultManager];
      if (![manager fileExistsAtPath:copy]) {
        [manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSError* error = nil;
        const BOOL copied = [manager copyItemAtPath:[support stringByAppendingPathComponent:@"mcla"]
                                             toPath:copy
                                              error:&error];
        printf("[mcla-ios] test user folder %s: %s\n", user_root,
               copied ? "copied from the player's" : error.localizedDescription.UTF8String);
      }
      printf("[mcla-ios] user folder: Library/Application Support/%s (test run, no save sync)\n", user_root);
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

// --- Where the time goes: a sampling profiler --------------------------------
//
// With MCLA_PROFILE=1 (mcla-env.txt), each perf line is followed by where the
// busiest threads and the GPU command thread were in 100 samples taken over
// half a second: the innermost named frames of the most frequent stacks.
// A thread is suspended for a sample; nothing between suspend and resume
// allocates, logs or takes a lock (the thread may hold malloc's).

constexpr int kProfileFrames = 20;
constexpr int kProfileSamples = 100;
constexpr int kProfileThreads = 4;

struct ProfileSample {
  uint64_t frames[kProfileFrames];
  int count;
};
ProfileSample g_profile_samples[kProfileThreads][kProfileSamples];

uint64_t StripPointer(uint64_t pointer) { return pointer & 0x00007FFFFFFFFFFFull; }

void SampleThread(thread_act_t thread, ProfileSample* sample) {
  sample->count = 0;
  if (thread_suspend(thread) != KERN_SUCCESS) {
    return;
  }
  arm_thread_state64_t state;
  mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
  if (thread_get_state(thread, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state),
                       &state_count) == KERN_SUCCESS) {
    sample->frames[sample->count++] = StripPointer(arm_thread_state64_get_pc(state));
    uint64_t fp = arm_thread_state64_get_fp(state);
    while (fp && !(fp & 7) && sample->count < kProfileFrames) {
      uint64_t record[2];
      vm_size_t read = 0;
      if (vm_read_overwrite(mach_task_self(), fp, sizeof(record),
                            reinterpret_cast<vm_address_t>(record), &read) != KERN_SUCCESS ||
          read != sizeof(record)) {
        break;
      }
      const uint64_t return_address = StripPointer(record[1]);
      if (!return_address) {
        break;
      }
      sample->frames[sample->count++] = return_address;
      if (record[0] <= fp) {
        break;
      }
      fp = record[0];
    }
  }
  thread_resume(thread);
}

std::string SymbolName(uint64_t address, std::map<uint64_t, std::string>& cache) {
  auto found = cache.find(address);
  if (found != cache.end()) {
    return found->second;
  }
  std::string name;
  Dl_info info;
  if (dladdr(reinterpret_cast<void*>(address), &info) && info.dli_fname) {
    const char* image = strrchr(info.dli_fname, '/');
    image = image ? image + 1 : info.dli_fname;
    char text[200];
    if (info.dli_sname) {
      snprintf(text, sizeof(text), "%.110s", info.dli_sname);
    } else {
      snprintf(text, sizeof(text), "%.40s+0x%llx", image,
               (unsigned long long)(address - reinterpret_cast<uint64_t>(info.dli_fbase)));
    }
    name = text;
  } else {
    char text[32];
    snprintf(text, sizeof(text), "0x%llx", (unsigned long long)address);
    name = text;
  }
  cache[address] = name;
  return name;
}

struct ProfileTarget {
  thread_act_t thread;
  std::string name;
};

void ProfileThreads(const std::vector<ProfileTarget>& targets) {
  const int thread_count = int(std::min<size_t>(targets.size(), kProfileThreads));
  for (int sample = 0; sample < kProfileSamples; ++sample) {
    for (int t = 0; t < thread_count; ++t) {
      SampleThread(targets[t].thread, &g_profile_samples[t][sample]);
    }
    usleep(5000);
  }
  static std::map<uint64_t, std::string> cache;
  for (int t = 0; t < thread_count; ++t) {
    std::map<std::string, int> stacks;
    std::map<std::string, int> leaves;
    for (int sample = 0; sample < kProfileSamples; ++sample) {
      const ProfileSample& taken = g_profile_samples[t][sample];
      if (!taken.count) {
        continue;
      }
      std::string stack;
      for (int f = 0; f < taken.count && f < 7; ++f) {
        stack += (f ? " < " : "") + SymbolName(taken.frames[f], cache);
      }
      ++stacks[stack];
      ++leaves[SymbolName(taken.frames[0], cache)];
    }
    std::vector<std::pair<int, std::string>> order;
    for (const auto& [stack, count] : stacks) {
      order.emplace_back(count, stack);
    }
    std::sort(order.rbegin(), order.rend());
    printf("[mcla-prof] %s: %zu distinct stacks\n", targets[t].name.c_str(), order.size());
    for (size_t i = 0; i < order.size() && i < 6; ++i) {
      printf("[mcla-prof]   %3d%% %s\n", order[i].first, order[i].second.c_str());
    }
    order.clear();
    for (const auto& [leaf, count] : leaves) {
      order.emplace_back(count, leaf);
    }
    std::sort(order.rbegin(), order.rend());
    std::string line;
    for (size_t i = 0; i < order.size() && i < 8; ++i) {
      line += (i ? ", " : "") + std::to_string(order[i].first) + "% " + order[i].second;
    }
    printf("[mcla-prof]   leaves: %s\n", line.c_str());
  }
}

// "Preparing shaders 812 / 1578" over the black screen while the stored
// pipelines are created at start (a minute or two the first time, seconds
// after): without it the app looks hung.
void ShowStartupProgress() {
  static UILabel* label = nil;
  static dispatch_source_t timer = nil;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 4,
                            NSEC_PER_SEC / 20);
  dispatch_source_set_event_handler(timer, ^{
    unsigned long long done = 0, total = 0;
    rex::ui::GetStartupProgress(&done, &total);
    const bool busy = total != 0 && done < total;
    if (busy) {
      if (!label) {
        UIWindow* window = nil;
        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
          if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene* window_scene = (UIWindowScene*)scene;
            window = window_scene.keyWindow ?: window_scene.windows.firstObject;
            if (window) {
              break;
            }
          }
        }
        if (!window) {
          return;
        }
        label = [[UILabel alloc] initWithFrame:window.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = UIColor.blackColor;
        label.numberOfLines = 2;
        label.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightMedium];
        label.userInteractionEnabled = NO;
        [window addSubview:label];
      }
      [label.superview bringSubviewToFront:label];
      label.text = [NSString stringWithFormat:@"Preparing shaders\n%llu / %llu", done, total];
    } else if (label) {
      [label removeFromSuperview];
      label = nil;
    }
    if (total != 0 && done >= total && timer) {
      dispatch_source_cancel(timer);
      timer = nil;
    }
  });
  dispatch_resume(timer);
}

// A line every five seconds while the game is in front: frames presented a
// second, what the Vulkan calls that hand work to Metal cost a frame, the
// phone's thermal state, and the threads that use the most CPU. It is what
// says whether a slow game waits on the CPU (one thread near 100%), on the
// GPU (long presents) or on heat (thermal 2 and up: iOS slows the chip).
void PerfLogThread() {
  pthread_setname_np("mcla perf log");
  struct Usage {
    std::string name;
    int permille;
    thread_act_t thread;
  };
  const char* profile_setting = getenv("MCLA_PROFILE");
  const bool profile = profile_setting && profile_setting[0] == '1';
  rex::ui::GpuCallStats before = rex::ui::GetGpuCallStats();
  unsigned long long metal_before[8] = {};
  MclaIosMetalStatsRead(metal_before);
  uint64_t waits_before[4] = {};
  rex::graphics::vulkan::SubmissionCounters(waits_before);
  uint64_t draws_before = rex::graphics::vulkan::DrawCounter();
  uint64_t host_draws_before = rex::graphics::vulkan::HostDrawCounter();
  const int kSeconds = 5;
  for (int elapsed = kSeconds;; elapsed += kSeconds) {
    sleep(kSeconds);
    const rex::ui::GpuCallStats now = rex::ui::GetGpuCallStats();
    if (rex::ui::IsAppInBackground()) {
      before = now;
      continue;
    }
    const double presents = double(now.calls[1] - before.calls[1]);
    const double frames = presents > 0 ? presents : 1;
    double ms[3];
    for (int i = 0; i < 3; ++i) {
      ms[i] = double(now.nanoseconds[i] - before.nanoseconds[i]) / 1e6 / frames;
    }
    const double submits = double(now.calls[0] - before.calls[0]);
    double recorded[rex::ui::kGpuCallKinds];
    for (int i = 3; i < rex::ui::kGpuCallKinds; ++i) {
      recorded[i] = double(now.calls[i] - before.calls[i]) / frames;
    }
    before = now;

    std::vector<Usage> usage;
    int total = 0;
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t thread_count = 0;
    if (task_threads(mach_task_self(), &threads, &thread_count) == KERN_SUCCESS) {
      for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t info_count = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, reinterpret_cast<thread_info_t>(&info),
                        &info_count) == KERN_SUCCESS &&
            !(info.flags & TH_FLAGS_IDLE)) {
          char name[64] = "";
          if (pthread_t thread = pthread_from_mach_thread_np(threads[i])) {
            pthread_getname_np(thread, name, sizeof(name));
          }
          total += info.cpu_usage;
          const bool gpu_thread = strncmp(name, "GPU Commands", 12) == 0;
          if (info.cpu_usage >= 30 || gpu_thread) {
            // The GPU command thread first: it is the one the frame waits for.
            usage.push_back({name[0] ? name : "(unnamed)",
                             int(info.cpu_usage) + (gpu_thread ? 100000 : 0), threads[i]});
          }
        }
      }
    }
    std::sort(usage.begin(), usage.end(),
              [](const Usage& a, const Usage& b) { return a.permille > b.permille; });
    std::string top;
    for (size_t i = 0; i < usage.size() && i < 8; ++i) {
      char item[96];
      snprintf(item, sizeof(item), "%s%s %d%%", i ? ", " : "", usage[i].name.c_str(),
               (usage[i].permille % 100000) / 10);
      top += item;
    }
    char clock[16] = "";
    const time_t wall = time(nullptr);
    strftime(clock, sizeof(clock), "%H:%M:%S", localtime(&wall));
    printf("[mcla-perf] %s %4ds  %.1f fps, %.1f submits/frame; per frame: submit %.1f ms, present %.1f ms, "
           "acquire %.1f ms; thermal %ld; %d threads, cpu %d%%: %s\n",
           clock, elapsed, presents / kSeconds, submits / frames, ms[0], ms[1], ms[2],
           (long)NSProcessInfo.processInfo.thermalState, int(thread_count), total / 10, top.c_str());
    printf("[mcla-perf]        per frame: %.0f render passes, %.0f draws, %.0f buffer copies, %.0f texture "
           "uploads, %.0f dispatches, %.0f barriers, %.0f pipeline binds\n",
           recorded[3], recorded[4], recorded[5], recorded[6], recorded[7], recorded[8], recorded[9]);
    // A blocking wait is the command processor standing still until the GPU
    // has finished what was submitted: one a frame is the queue's limit (the
    // GPU is behind), more are readbacks and other synchronous points, which
    // take the overlap between the two away.
    uint64_t waits_now[4] = {};
    rex::graphics::vulkan::SubmissionCounters(waits_now);
    const uint64_t draws_now = rex::graphics::vulkan::DrawCounter();
    const uint64_t host_draws_now = rex::graphics::vulkan::HostDrawCounter();
    printf("[mcla-perf]        GPU waits per frame: %.2f blocking (%.1f ms); %.0f guest draws, %.0f host draws\n",
           double(waits_now[2] - waits_before[2]) / frames,
           double(waits_now[3] - waits_before[3]) / 1e3 / frames, double(draws_now - draws_before) / frames,
           double(host_draws_now - host_draws_before) / frames);
    for (int i = 0; i < 4; ++i) {
      waits_before[i] = waits_now[i];
    }
    draws_before = draws_now;
    host_draws_before = host_draws_now;
    printf("[mcla-perf]        %.1f render passes begun per frame by the command processor\n", recorded[18]);
    printf("[mcla-perf]        pass ends per frame: %.1f uploads, %.1f textures, %.1f resolves, %.1f queries, "
           "%.1f submissions, %.1f target changes, %.1f barriers, %.1f other\n",
           recorded[10], recorded[11], recorded[12], recorded[13], recorded[14], recorded[15], recorded[17],
           recorded[16]);
    unsigned long long metal_now[8] = {};
    if (MclaIosMetalStatsRead(metal_now)) {
      double metal[8];
      for (int i = 0; i < 8; ++i) {
        metal[i] = double(metal_now[i] - metal_before[i]) / frames;
        metal_before[i] = metal_now[i];
      }
      printf("[mcla-perf]        Metal per frame: %.1f render passes (%.1f load nothing, %.1f multisampled), "
             "%.2f M samples loaded, %.2f M stored, %.1f compute passes, %.1f blit passes, %.1f command buffers\n",
             metal[0], metal[5], metal[7], metal[3] / 1e6, metal[4] / 1e6, metal[1], metal[2], metal[6]);
    }
    if (profile && presents > 0) {
      std::vector<ProfileTarget> targets;
      const pthread_t self = pthread_self();
      for (const Usage& candidate : usage) {
        if (pthread_from_mach_thread_np(candidate.thread) != self) {
          targets.push_back({candidate.thread, candidate.name});
        }
      }
      ProfileThreads(targets);
    }
    for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
      mach_port_deallocate(mach_task_self(), threads[i]);
    }
    if (threads) {
      vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads),
                    thread_count * sizeof(thread_act_t));
    }
  }
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
  // Measured on an iPhone 17 Pro Max (2026-11-15): the GPU is the limit, and
  // the game's own "low" preset (no anti-aliasing, no full-screen blur, the
  // environment map every 4th frame) took the city from 7-12 to 20-26 frames a
  // second. Until the renderer suits a tile-based GPU better, every device
  // starts with it at the console's resolution; the pause menu's PERFORMANCE
  // tab and mcla.toml change it.
  const Default large_defaults[] = {{"resolution_scale", "1"}, {"mcla_preset", "low"}};
  const Default small_defaults[] = {{"resolution_scale", "1"}, {"mcla_preset", "low"}};
  const Default* defaults = large ? large_defaults : small_defaults;
  const size_t count = large ? std::size(large_defaults) : std::size(small_defaults);

  // The fork's PC default, an EDRAM of 4,096 tiles so that the scene is one
  // tile, left the lower part of the frame as the blur layer on MoltenVK on
  // the first devices (the part past the console's 2,048 tiles, it seems): the
  // console's size here, set as the command line would so that the PC default
  // doesn't replace it.
  // (MCLA_EDRAM_TILES=4096 in mcla-env.txt brings the fork's back, to study it.)
  const char* edram_tiles = getenv("MCLA_EDRAM_TILES");
  rex::cvar::SetFlagFromCommandLine("edram_tiles", edram_tiles ? edram_tiles : "2048");

  MclaIosMetalStatsInstall();
  std::thread(PerfLogThread).detach();
  ShowStartupProgress();
  MclaIosStartTouchControls();

  printf("[mcla-ios] device class: %s (%s)\n", large ? "M-class iPad" : "phone-class", machine);
  for (size_t i = 0; i < count; ++i) {
    const bool taken = rex::cvar::SetDefaultValue(defaults[i].name, defaults[i].value);
    printf("[mcla-ios]   %s = %s%s\n", defaults[i].name, defaults[i].value, taken ? "" : " (not taken)");
  }
}
