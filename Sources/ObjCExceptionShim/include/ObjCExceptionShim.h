#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the NSException it raised, or nil.
///
/// AVFAudio validates formats and devices inside calls such as
/// -[AVAudioEngine connect:to:format:], -[AVAudioEngine startAndReturnError:]
/// and -[AVAudioNode installTapOnBus:bufferSize:format:block:], and raises an
/// Objective-C exception, rather than returning an error, when the hardware
/// changed under it. Swift cannot catch those, so a device that moves between
/// being read and being used ends the process. This is the one supported way
/// to survive such a call.
NSException *_Nullable ALBCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
