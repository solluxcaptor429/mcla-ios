// On-screen controls for playing without a controller.
//
// The system's own virtual controller (GCVirtualController) draws a left stick,
// a d-pad, A/B/X/Y, both shoulders and both triggers over the game and shows up
// as an ordinary extended gamepad, which SDL and the runtime's input system
// take like a Backbone or a DualSense. It has no Start and Back, which the game
// needs (the title screen, the pause menu, the GPS map): two small buttons of
// our own at the top of the screen set those bits in the pad state the runtime
// reports (rex/ui/app_background.h).
//
// The controls are there only while no physical controller is connected: when
// one connects they go away, when the last one disconnects they come back.
// MCLA_TOUCH=0 (Documents/mcla-env.txt) turns them off.

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <stdio.h>
#include <stdlib.h>

#include <rex/ui/app_background.h>

namespace {

constexpr unsigned kPadStart = 0x0010;  // X_INPUT_GAMEPAD_START
constexpr unsigned kPadBack = 0x0020;   // X_INPUT_GAMEPAD_BACK

GCVirtualController* g_virtual = nil;
bool g_virtual_connected = false;
bool g_virtual_connecting = false;
UIView* g_buttons = nil;
unsigned g_extra = 0;

UIWindow* GameWindow() {
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene* window_scene = (UIWindowScene*)scene;
      UIWindow* window = window_scene.keyWindow ?: window_scene.windows.firstObject;
      if (window) {
        return window;
      }
    }
  }
  return nil;
}

bool PhysicalControllerConnected() {
  for (GCController* controller in GCController.controllers) {
    if (g_virtual && controller == g_virtual.controller) {
      continue;
    }
    // The virtual one, seen before its own property says so.
    if ([controller.vendorName containsString:@"Virtual"] || [controller.vendorName containsString:@"Touch"]) {
      continue;
    }
    return true;
  }
  return false;
}

}  // namespace

// A button that holds a bit of the pad state while a finger is on it.
@interface MclaPadButton : UIButton
@property(nonatomic) unsigned padBit;
@end

@implementation MclaPadButton
- (void)press {
  g_extra |= self.padBit;
  rex::ui::SetExtraPadButtons(g_extra);
  self.alpha = 0.9;
}
- (void)lift {
  g_extra &= ~self.padBit;
  rex::ui::SetExtraPadButtons(g_extra);
  self.alpha = 0.45;
}
@end

namespace {

MclaPadButton* MakeButton(NSString* title, unsigned bit) {
  MclaPadButton* button = [MclaPadButton buttonWithType:UIButtonTypeCustom];
  button.padBit = bit;
  [button setTitle:title forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
  [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
  button.layer.cornerRadius = 14;
  button.layer.borderWidth = 1;
  button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
  button.alpha = 0.45;
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [button addTarget:button action:@selector(press) forControlEvents:UIControlEventTouchDown];
  [button addTarget:button
                action:@selector(lift)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                       UIControlEventTouchCancel];
  return button;
}

void ShowButtons(bool show) {
  if (!show) {
    g_buttons.hidden = YES;
    g_extra = 0;
    rex::ui::SetExtraPadButtons(0);
    return;
  }
  if (!g_buttons) {
    UIWindow* window = GameWindow();
    if (!window) {
      return;
    }
    // Only as large as the two buttons: every other touch goes to the game
    // and to the virtual controller.
    g_buttons = [[UIView alloc] init];
    g_buttons.translatesAutoresizingMaskIntoConstraints = NO;
    MclaPadButton* back = MakeButton(@"BACK", kPadBack);
    MclaPadButton* start = MakeButton(@"START", kPadStart);
    [g_buttons addSubview:back];
    [g_buttons addSubview:start];
    [window addSubview:g_buttons];
    UILayoutGuide* safe = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
      [g_buttons.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
      [g_buttons.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
      [g_buttons.heightAnchor constraintEqualToConstant:28],
      [back.leadingAnchor constraintEqualToAnchor:g_buttons.leadingAnchor],
      [back.topAnchor constraintEqualToAnchor:g_buttons.topAnchor],
      [back.bottomAnchor constraintEqualToAnchor:g_buttons.bottomAnchor],
      [back.widthAnchor constraintEqualToConstant:76],
      [start.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:28],
      [start.topAnchor constraintEqualToAnchor:g_buttons.topAnchor],
      [start.bottomAnchor constraintEqualToAnchor:g_buttons.bottomAnchor],
      [start.widthAnchor constraintEqualToConstant:76],
      [start.trailingAnchor constraintEqualToAnchor:g_buttons.trailingAnchor],
    ]];
  }
  g_buttons.hidden = NO;
  [g_buttons.superview bringSubviewToFront:g_buttons];
}

// Called on the main thread whenever the set of controllers may have changed.
void UpdateTouchControls() {
  const bool physical = PhysicalControllerConnected();
  if (physical) {
    if (g_virtual_connected) {
      [g_virtual disconnect];
      g_virtual_connected = false;
      printf("[mcla-ios] touch controls off: a controller is connected\n");
    }
    ShowButtons(false);
    return;
  }
  if (!GameWindow()) {
    return;  // Too early: the next tick tries again.
  }
  if (!g_virtual) {
    GCVirtualControllerConfiguration* configuration = [[GCVirtualControllerConfiguration alloc] init];
    configuration.elements = [NSSet setWithObjects:GCInputLeftThumbstick, GCInputDirectionPad, GCInputButtonA,
                                                   GCInputButtonB, GCInputButtonX, GCInputButtonY,
                                                   GCInputLeftShoulder, GCInputRightShoulder,
                                                   GCInputLeftTrigger, GCInputRightTrigger, nil];
    g_virtual = [GCVirtualController virtualControllerWithConfiguration:configuration];
  }
  if (!g_virtual_connected && !g_virtual_connecting) {
    g_virtual_connecting = true;
    [g_virtual connectWithReplyHandler:^(NSError* error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        g_virtual_connecting = false;
        g_virtual_connected = error == nil;
        printf("[mcla-ios] touch controls %s%s\n", error ? "not shown: " : "on",
               error ? error.localizedDescription.UTF8String : "");
        if (!error) {
          ShowButtons(true);
        }
      });
    }];
  }
  if (g_virtual_connected) {
    ShowButtons(true);
  }
}

}  // namespace

extern "C" void MclaIosStartTouchControls(void) {
  const char* setting = getenv("MCLA_TOUCH");
  if (setting && setting[0] == '0') {
    printf("[mcla-ios] touch controls off (MCLA_TOUCH=0)\n");
    return;
  }
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  for (NSNotificationName name in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ]) {
    [center addObserverForName:name
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification*) {
                      UpdateTouchControls();
                    }];
  }
  // The window does not exist yet, and a controller that is already plugged
  // in announces itself a moment after the start: look a few times.
  static dispatch_source_t timer = nil;
  static int ticks = 0;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), NSEC_PER_SEC,
                            NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(timer, ^{
    UpdateTouchControls();
    if (++ticks >= 15 && timer) {
      dispatch_source_cancel(timer);
      timer = nil;
    }
  });
  dispatch_resume(timer);
}
