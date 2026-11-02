#import <AppKit/AppKit.h>
#import <assert.h>
#import "Pinch.h"

static CGEventRef zoomEvent(int phase, double amount, CGPoint location);
static BOOL launchedAtLogin(NSAppleEventDescriptor *event);

static void runTests(void) {
    assert(validSensitivity(NAN) == 1.0);
    assert(validSensitivity(0.1) == 0.5 && validSensitivity(3.0) == 2.0);
    assert(fabs(validSensitivity(1.24) - 1.2) < 0.00001);
    assert(fabs(scaledZoomAmount(0.04, 0.5) - 0.02) < 0.00001);
    assert(fabs(scaledZoomAmount(0.04, 1.0) - 0.04) < 0.00001);
    assert(fabs(scaledZoomAmount(0.04, 2.0) - 0.08) < 0.00001);
    assert(fabs(scaledZoomAmount(0.10, 2.0) - 0.15) < 0.00001);
    assert(fabs(scaledZoomAmount(-0.10, 2.0) + 0.15) < 0.00001);

    PinchState state = {0};
    Contact fingers[] = {{1, 0.2, 0.5}, {2, 0.4, 0.5}};
    assert(pinchUpdate(&state, fingers, 2).phase == 0);
    fingers[1].x = 0.41;
    assert(pinchUpdate(&state, fingers, 2).phase == 0);
    fingers[1].x = 0.44;
    PinchResult result = pinchUpdate(&state, fingers, 2);
    assert(result.phase == 1 && result.amount > 0);
    fingers[1].x = 0.43;
    result = pinchUpdate(&state, fingers, 2);
    assert(result.phase == 2 && result.amount < 0);
    assert(pinchUpdate(&state, fingers, 1).phase == 4);
    assert(pinchUpdate(&state, fingers, 1).phase == 0);
    fingers[0].x = 0.2;
    fingers[1].x = 0.4;
    pinchUpdate(&state, fingers, 2);
    fingers[0].x += 0.2;
    fingers[1].x += 0.2;
    assert(pinchUpdate(&state, fingers, 2).phase == 0);
    pinchUpdate(&state, NULL, 0);
    fingers[0].x = 0.2;
    fingers[1].x = 0.43;
    pinchUpdate(&state, fingers, 2);
    fingers[1].x = 0.5;
    assert(pinchUpdate(&state, fingers, 2).phase == 1);
    fingers[1].id = 3;
    assert(pinchUpdate(&state, fingers, 2).phase == 4);
    fingers[1].x = NAN;
    assert(pinchUpdate(&state, fingers, 2).phase == 0);

    for (int phase = 1; phase <= 4; phase *= 2) {
        CGEventRef event = zoomEvent(phase, 0.125, CGPointMake(15, 20));
        assert(event != NULL);
        NSEvent *native = [NSEvent eventWithCGEvent:event];
        assert(native != nil && native.type == NSEventTypeMagnify);
        NSEventPhase expected = phase == 1 ? NSEventPhaseBegan :
                                phase == 2 ? NSEventPhaseChanged : NSEventPhaseEnded;
        assert(native.phase == expected && fabs(native.magnification - 0.125) < 0.00001);
        CFRelease(event);
    }
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass
        eventID:kAEOpenApplication targetDescriptor:nil returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    assert(!launchedAtLogin(nil) && !launchedAtLogin(event));
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:keyAELaunchedAsLogInItem]
                  forKeyword:keyAEPropData];
    assert(launchedAtLogin(event));
    puts("Sensitivity, pinch, magnification event, and login-launch checks passed.");
}
