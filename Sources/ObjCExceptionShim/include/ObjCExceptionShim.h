#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the NSException it raised, or nil.
///
/// AVFAudio validates formats inside -[AVAudioNode installTapOnBus:] and
/// raises an Objective-C exception on a mismatch. Swift cannot catch those,
/// so a hardware format that moves between being read and being used —
/// which is what a device change in flight does — kills the process. This
/// is the one supported way to survive that call.
NSException *_Nullable ALBCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
