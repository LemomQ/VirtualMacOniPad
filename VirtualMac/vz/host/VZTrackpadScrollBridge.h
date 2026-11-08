#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (*VZTrackpadScrollEmitter)(CGVector rawDelta,
                                        CGVector acceleratedDelta,
                                        NSUInteger phase,
                                        NSUInteger momentumPhase,
                                        void *context);

// Reconstructs the macOS trackpad scroll pipeline which is absent from the
// iPad UIScrollEvent stream. The implementation mirrors the Ventura
// MultitouchHID momentum estimator followed by IOHID's scroll accelerator.
// All entry points and the emitter run on the main thread.
void VZTrackpadScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                     void * _Nullable context);
// Presentation speed multiplier for trackpad scrolling. 1.0 keeps the
// reconstructed Ventura curve; lower values move the guest content less for
// the same finger travel, which suits a small Magic Keyboard trackpad.
void VZTrackpadScrollBridgeSetOutputScale(double scale);
void VZTrackpadScrollBridgeHandle(CGVector rawDelta,
                                  NSUInteger phase,
                                  CFTimeInterval timestamp);
// Stop only an in-flight hardware-trackpad momentum sequence. UIKit's
// private scroll-deceleration interrupter invokes this on light finger
// contact, before an ordinary UITouch/click exists.
void VZTrackpadScrollBridgeInterruptMomentum(void);
BOOL VZTrackpadScrollBridgeHasMomentum(void);
// Magic Mouse surface input has a trackpad-like contact lifecycle on iPadOS,
// but it does not receive macOS momentum from the host. Keep it in a separate
// pipeline so its acceleration and momentum history cannot affect a trackpad.
void VZSurfaceMouseScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                         void * _Nullable context);
void VZSurfaceMouseScrollBridgeHandle(CGVector rawDelta,
                                      NSUInteger phase,
                                      CFTimeInterval timestamp);
void VZSurfaceMouseScrollBridgeInterruptMomentum(void);
BOOL VZSurfaceMouseScrollBridgeHasMomentum(void);
// Direct touch does not provide macOS trackpad mickeys or momentum packets.
// Run it through an independent copy of the same state machine so touch and
// hardware-trackpad gestures cannot contaminate one another's history.
void VZTouchScrollBridgeConfigure(VZTrackpadScrollEmitter emitter,
                                  void * _Nullable context);
void VZTouchScrollBridgeHandle(CGVector translationDelta,
                               NSUInteger phase,
                               CFTimeInterval timestamp,
                               CGFloat speed);
void VZTouchScrollBridgeInterruptMomentum(void);
BOOL VZTouchScrollBridgeHasMomentum(void);
void VZTrackpadScrollBridgeReset(void);

NS_ASSUME_NONNULL_END
