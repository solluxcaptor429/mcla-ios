// The save sync's place in the app's life (sync/mclasync.go does the syncing).
//
//   start         before the runtime: pull what the PC or the Deck saved since,
//                 waiting a few seconds at most, then let the game start.
//   playing       Syncthing watches the save folder and sends each save.
//   background    send what is left while iOS still lets the app run.
//   foreground    look at the folder again.
//
// None of it can stop the game: without the setup files, or when no other
// device is reachable, the game plays with the saves on this device.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <stdio.h>

#if MCLA_HAVE_SYNC
#include "libmclasync.h"
#endif

namespace {

#if MCLA_HAVE_SYNC
// How long to wait at start: for any other device to be reachable at all, and
// in all. Saves are small; the wait is for the connection, not the data.
constexpr int kConnectWaitMs = 4000;
constexpr int kTotalWaitMs = 12000;
constexpr int kBackgroundWaitMs = 20000;

bool g_running = false;
UIBackgroundTaskIdentifier g_task = UIBackgroundTaskInvalid;

void EndBackgroundTask() {
  if (g_task != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:g_task];
    g_task = UIBackgroundTaskInvalid;
  }
}

void ObserveAppState() {
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                      object:nil
                       queue:[NSOperationQueue mainQueue]
                  usingBlock:^(NSNotification*) {
                    EndBackgroundTask();
                    g_task = [[UIApplication sharedApplication]
                        beginBackgroundTaskWithName:@"mcla save sync"
                                  expirationHandler:^{
                                    EndBackgroundTask();
                                  }];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                      MclaSyncRescan();
                      const int result = MclaSyncWait(1500, kBackgroundWaitMs);
                      printf("[mcla-ios] save sync before suspending: %d\n", result);
                      dispatch_async(dispatch_get_main_queue(), ^{
                        EndBackgroundTask();
                      });
                    });
                  }];
  [center addObserverForName:UIApplicationWillEnterForegroundNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification*) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                      MclaSyncRescan();
                    });
                  }];
  [center addObserverForName:UIApplicationWillTerminateNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification*) {
                    MclaSyncRescan();
                    MclaSyncWait(500, 3000);
                    MclaSyncStop();
                  }];
}
#endif

}  // namespace

extern "C" void MclaIosApplyDeviceDefaults(void);  // ios_support.mm

extern "C" void rex_ios_before_app(void) {
  MclaIosApplyDeviceDefaults();
#if MCLA_HAVE_SYNC
  @autoreleasepool {
    NSString* home = NSHomeDirectory();
    NSString* support = [home stringByAppendingPathComponent:@"Library/Application Support"];
    // The runtime's user data folder (GetUserFolder() / the app's name): the
    // same layout as Documents\mcla on the PC.
    NSString* folder = [support stringByAppendingPathComponent:@"mcla"];
    NSString* sync_home = [support stringByAppendingPathComponent:@"mcla-sync"];
    NSString* inbox = [home stringByAppendingPathComponent:@"Documents/mcla-sync"];

    const int started = MclaSyncStart(const_cast<char*>(sync_home.fileSystemRepresentation),
                                      const_cast<char*>(folder.fileSystemRepresentation),
                                      const_cast<char*>(inbox.fileSystemRepresentation));
    if (started != 0) {
      printf("[mcla-ios] save sync off (%d)\n", started);
      return;
    }
    char id[80] = "";
    MclaSyncDeviceID(id, sizeof(id));
    printf("[mcla-ios] save sync: this device is %s\n", id);
    g_running = true;
    ObserveAppState();
    const int result = MclaSyncWait(kConnectWaitMs, kTotalWaitMs);
    printf("[mcla-ios] save sync at start: %d\n", result);
  }
#else
  printf("[mcla-ios] built without save sync\n");
#endif
}
