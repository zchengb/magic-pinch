/*
 * SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 zchengb
 * Multitouch declarations and device filtering are adapted from Magic Mouse Toolkit.
 * MouseToucher portions: Copyright (c) 2025 Roger Hughes. See THIRD_PARTY_NOTICES.txt.
 */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreServices/CoreServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#import "Pinch.h"

typedef void *MTDevice;
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t path, state, finger, hand;
    MTVector normalized;
    float size;
    int32_t unused1;
    float angle, major, minor;
    MTVector absolute;
    int32_t unused2, unused3;
    float density;
} MTTouch;
typedef int (*MTCallback)(MTDevice, MTTouch *, int, double, int);

static CFArrayRef (*mtList)(void);
static int (*mtFamily)(MTDevice, int32_t *);
static int (*mtDeviceID)(MTDevice, uint64_t *);
static bool (*mtBuiltIn)(MTDevice);
static void (*mtRegister)(MTDevice, MTCallback);
static void (*mtUnregister)(MTDevice, MTCallback);
static int (*mtStart)(MTDevice, int);
static int (*mtStop)(MTDevice);

static double validSensitivity(double value) {
    return isfinite(value) ? fmax(0.5, fmin(2.0, round(value * 10.0) / 10.0)) : 1.0;
}

static double scaledZoomAmount(double amount, double sensitivity) {
    return fmax(-0.15, fmin(0.15, amount * sensitivity));
}

// shortcut: these gesture fields are undocumented; retest after macOS upgrades.
static CGEventRef zoomEvent(int phase, double amount, CGPoint location) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;
    CGEventSetType(event, (CGEventType)29);
    CGEventSetIntegerValueField(event, (CGEventField)110, 8);
    CGEventSetIntegerValueField(event, (CGEventField)132, phase);
    CGEventSetDoubleValueField(event, (CGEventField)113, amount);
    CGEventSetLocation(event, location);
    return event;
}

static BOOL launchedAtLogin(NSAppleEventDescriptor *event) {
    return event && event.eventID == kAEOpenApplication &&
        [[event paramDescriptorForKeyword:keyAEPropData] enumCodeValue] == keyAELaunchedAsLogInItem;
}

#import "Tests.m"

@interface App : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property NSStatusItem *statusItem;
@property NSTextField *status;
@property NSImageView *statusIcon;
@property NSButton *inputButton;
@property NSButton *controlButton;
@property NSStackView *permissions;
@property NSSwitch *loginSwitch;
@property NSTextField *sensitivityValue;
@property double sensitivity;
@property NSTimer *timer;
@property MTDevice device;
@property uint64_t deviceID;
@property PinchState pinch;
@property CGPoint anchor;
@property BOOL frameworkReady;
@end

static App *app;
static int touchFrame(MTDevice device, MTTouch *touches, int count, double timestamp, int frame) {
    (void)timestamp; (void)frame;
    Contact first = {0}, second = {0};
    int active = 0;
    if (touches && count >= 0 && count <= 32) {
        for (int i = 0; i < count; i++) {
            if (touches[i].state != 3 && touches[i].state != 4) continue;
            Contact contact = {touches[i].path, touches[i].normalized.position.x,
                               touches[i].normalized.position.y};
            if (active == 0) first = contact;
            if (active == 1) second = contact;
            active++;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (app.device != device) return;
        Contact contacts[] = {first, second};
        PinchState pinch = app.pinch;
        PinchResult result = pinchUpdate(&pinch, contacts, active);
        app.pinch = pinch;
        if (!result.phase) return;
        if (result.phase == 1) {
            CGEventRef pointer = CGEventCreate(NULL);
            if (!pointer) return;
            app.anchor = CGEventGetLocation(pointer);
            CFRelease(pointer);
        }
        CGEventRef event = zoomEvent(result.phase, scaledZoomAmount(result.amount, app.sensitivity), app.anchor);
        if (event) { CGEventPost(kCGSessionEventTap, event); CFRelease(event); }
    });
    return 0;
}

static NSTextField *label(NSString *text, CGFloat size) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size];
    return field;
}

@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"PinchSensitivity": @1.0}];
    self.sensitivity = validSensitivity([NSUserDefaults.standardUserDefaults doubleForKey:@"PinchSensitivity"]);
    void *library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (library) {
        mtList = dlsym(library, "MTDeviceCreateList");
        mtFamily = dlsym(library, "MTDeviceGetFamilyID");
        mtDeviceID = dlsym(library, "MTDeviceGetDeviceID");
        mtBuiltIn = dlsym(library, "MTDeviceIsBuiltIn");
        mtRegister = dlsym(library, "MTRegisterContactFrameCallback");
        mtUnregister = dlsym(library, "MTUnregisterContactFrameCallback");
        mtStart = dlsym(library, "MTDeviceStart");
        mtStop = dlsym(library, "MTDeviceStop");
        self.frameworkReady = mtList && mtFamily && mtDeviceID && mtBuiltIn &&
                              mtRegister && mtUnregister && mtStart && mtStop;
    }

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"hand.pinch" accessibilityDescription:@"Magic Pinch"];
    if (!self.statusItem.button.image) self.statusItem.button.title = @"MP";
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *openItem = [menu addItemWithTitle:@"Open Magic Pinch" action:@selector(showWindow:) keyEquivalent:@""];
    openItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit Magic Pinch" action:@selector(terminate:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 285)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Magic Pinch";
    self.window.delegate = self;
    self.window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    [self.window center];
    NSView *view = self.window.contentView;

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:23],
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:view.bottomAnchor constant:-18]
    ]];

    NSTextField *title = label(@"Pinch to Zoom", 20);
    title.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    [stack addArrangedSubview:title];
    [stack setCustomSpacing:2 afterView:title];
    NSTextField *description = label(@"Use two fingers on your Magic Mouse.", 13);
    description.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:description];
    [stack setCustomSpacing:20 afterView:description];

    self.statusIcon = [[NSImageView alloc] init];
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusIcon.widthAnchor constraintEqualToConstant:17],
        [self.statusIcon.heightAnchor constraintEqualToConstant:17]
    ]];
    self.status = label(@"Checking…", 13);
    NSStackView *statusRow = [NSStackView stackViewWithViews:@[self.statusIcon, self.status]];
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.alignment = NSLayoutAttributeCenterY;
    statusRow.spacing = 8;
    [stack addArrangedSubview:statusRow];
    [stack setCustomSpacing:19 afterView:statusRow];

    NSBox *separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    [stack addArrangedSubview:separator];
    [separator.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [stack setCustomSpacing:16 afterView:separator];

    NSView *sensitivityRow = [[NSView alloc] init];
    [sensitivityRow.heightAnchor constraintEqualToConstant:28].active = YES;
    [stack addArrangedSubview:sensitivityRow];
    [sensitivityRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    NSTextField *sensitivityLabel = label(@"Sensitivity", 13);
    sensitivityLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSSlider *slider = [NSSlider sliderWithValue:self.sensitivity minValue:0.5 maxValue:2.0
                                         target:self action:@selector(changeSensitivity:)];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.continuous = YES;
    slider.accessibilityLabel = @"Zoom sensitivity";
    self.sensitivityValue = label([NSString stringWithFormat:@"%.1f×", self.sensitivity], 13);
    self.sensitivityValue.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.sensitivityValue.alignment = NSTextAlignmentRight;
    self.sensitivityValue.translatesAutoresizingMaskIntoConstraints = NO;
    [sensitivityRow addSubview:sensitivityLabel];
    [sensitivityRow addSubview:slider];
    [sensitivityRow addSubview:self.sensitivityValue];
    [NSLayoutConstraint activateConstraints:@[
        [sensitivityLabel.leadingAnchor constraintEqualToAnchor:sensitivityRow.leadingAnchor],
        [sensitivityLabel.centerYAnchor constraintEqualToAnchor:sensitivityRow.centerYAnchor],
        [slider.widthAnchor constraintEqualToConstant:170],
        [slider.trailingAnchor constraintEqualToAnchor:self.sensitivityValue.leadingAnchor constant:-10],
        [slider.centerYAnchor constraintEqualToAnchor:sensitivityRow.centerYAnchor],
        [self.sensitivityValue.widthAnchor constraintEqualToConstant:36],
        [self.sensitivityValue.trailingAnchor constraintEqualToAnchor:sensitivityRow.trailingAnchor],
        [self.sensitivityValue.centerYAnchor constraintEqualToAnchor:sensitivityRow.centerYAnchor]
    ]];
    [stack setCustomSpacing:12 afterView:sensitivityRow];

    NSView *loginRow = [[NSView alloc] init];
    [loginRow.heightAnchor constraintEqualToConstant:26].active = YES;
    [stack addArrangedSubview:loginRow];
    [loginRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    NSTextField *loginLabel = label(@"Open at Login", 13);
    loginLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginSwitch = [[NSSwitch alloc] init];
    self.loginSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginSwitch.target = self;
    self.loginSwitch.action = @selector(toggleLogin:);
    self.loginSwitch.accessibilityLabel = @"Open at Login";
    [loginRow addSubview:loginLabel];
    [loginRow addSubview:self.loginSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [loginLabel.leadingAnchor constraintEqualToAnchor:loginRow.leadingAnchor],
        [loginLabel.centerYAnchor constraintEqualToAnchor:loginRow.centerYAnchor],
        [self.loginSwitch.trailingAnchor constraintEqualToAnchor:loginRow.trailingAnchor],
        [self.loginSwitch.centerYAnchor constraintEqualToAnchor:loginRow.centerYAnchor]
    ]];
    [stack setCustomSpacing:18 afterView:loginRow];

    self.inputButton = [NSButton buttonWithTitle:@"Allow Input Monitoring" target:self action:@selector(requestInput:)];
    self.controlButton = [NSButton buttonWithTitle:@"Allow Device Control" target:self action:@selector(requestControl:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.inputButton, self.controlButton]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    NSTextField *permissionLabel = label(@"Allow access in System Settings to enable zoom.", 12);
    permissionLabel.textColor = NSColor.secondaryLabelColor;
    self.permissions = [NSStackView stackViewWithViews:@[permissionLabel, buttons]];
    self.permissions.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.permissions.alignment = NSLayoutAttributeLeading;
    self.permissions.spacing = 8;
    [stack addArrangedSubview:self.permissions];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [self refresh:nil];
    NSAppleEventDescriptor *event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
    if (!launchedAtLogin(event) || !CGPreflightListenEventAccess() || !AXIsProcessTrusted()) [self showWindow:nil];
}

- (void)showWindow:(id)sender {
    (void)sender;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application; (void)visible;
    [self showWindow:nil];
    return YES;
}
- (void)changeSensitivity:(NSSlider *)sender {
    self.sensitivity = validSensitivity(sender.doubleValue);
    sender.doubleValue = self.sensitivity;
    self.sensitivityValue.stringValue = [NSString stringWithFormat:@"%.1f×", self.sensitivity];
    [NSUserDefaults.standardUserDefaults setDouble:self.sensitivity forKey:@"PinchSensitivity"];
}
- (void)toggleLogin:(NSSwitch *)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = sender.state == NSControlStateValueOn ?
        [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
    if (!success) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Couldn’t update Open at Login";
        alert.informativeText = error.localizedDescription ?: @"Check Login Items in System Settings.";
        [alert runModal];
        if (service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    }
    [self refresh:nil];
}
- (void)requestInput:(id)sender {
    (void)sender;
    CGRequestListenEventAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}
- (void)requestControl:(id)sender {
    (void)sender;
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
}
- (void)stopDevice {
    MTDevice old = self.device;
    self.device = NULL;
    self.deviceID = 0;
    self.pinch = (PinchState){0};
    if (old) {
        mtUnregister(old, touchFrame);
        mtStop(old);
        CFRelease(old);
    }
}
- (void)setStatusText:(NSString *)text ready:(BOOL)ready {
    self.status.stringValue = text;
    self.statusIcon.image = [NSImage imageWithSystemSymbolName:ready ? @"checkmark.circle.fill" : @"circle.dotted"
                                          accessibilityDescription:nil];
    self.statusIcon.contentTintColor = ready ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
}
- (void)refresh:(NSTimer *)timer {
    (void)timer;
    BOOL input = CGPreflightListenEventAccess();
    BOOL control = AXIsProcessTrusted();
    self.loginSwitch.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ?
        NSControlStateValueOn : NSControlStateValueOff;
    self.inputButton.hidden = input;
    self.controlButton.hidden = control;
    self.permissions.hidden = input && control;
    CGFloat height = self.permissions.hidden ? 285 : 360;
    if (fabs(self.window.contentView.bounds.size.height - height) > 1) {
        NSRect frame = self.window.frame;
        NSRect resized = [self.window frameRectForContentRect:NSMakeRect(0, 0, 440, height)];
        resized.origin = NSMakePoint(frame.origin.x, NSMaxY(frame) - resized.size.height);
        [self.window setFrame:resized display:YES];
    }
    if (!self.frameworkReady || !input || !control) {
        if (self.device) [self stopDevice];
        [self setStatusText:!self.frameworkReady ? @"This macOS version is not supported." :
                            @"Permissions required" ready:NO];
        return;
    }
    CFArrayRef devices = mtList();
    MTDevice match = NULL;
    uint64_t matchID = 0;
    if (devices) {
        for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
            MTDevice candidate = (MTDevice)CFArrayGetValueAtIndex(devices, i);
            int32_t family = -1;
            uint64_t identifier = 0;
            if (!mtBuiltIn(candidate) && mtFamily(candidate, &family) == 0 &&
                (family == 112 || family == 113) && mtDeviceID(candidate, &identifier) == 0) {
                match = candidate;
                matchID = identifier;
                break;
            }
        }
    }
    if (!match || matchID != self.deviceID) {
        if (self.device) [self stopDevice];
        if (match) {
            self.device = (MTDevice)CFRetain(match);
            self.deviceID = matchID;
            mtRegister(self.device, touchFrame);
            if (mtStart(self.device, 0) != 0) [self stopDevice];
        }
    }
    if (devices) CFRelease(devices);
    [self setStatusText:self.device ? @"Magic Mouse connected" : @"Waiting for Magic Mouse"
                  ready:self.device != NULL];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
    if (self.device) [self stopDevice];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) { runTests(); return 0; }
        if (argc == 2 && strcmp(argv[1], "--permissions") == 0) {
            printf("input=%d control=%d\n", CGPreflightListenEventAccess(), AXIsProcessTrusted());
            return 0;
        }
        [NSApplication sharedApplication];
        app = [App new];
        NSApp.delegate = app;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp run];
    }
    return 0;
}
