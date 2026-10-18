#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:] inside
/// @try/@catch. Swift cannot catch NSException, so without this a settings
/// validation failure inside AVFCapture terminates the app with SIGABRT
/// (VVCapture 1.0 build 2, TestFlight 2026-10-18: uncaught NSException from
/// capturePhotoWithSettings:delegate: on the first turntable shot).
///
/// Returns nil when the capture request was accepted, or an NSError carrying
/// the exception's name and reason when validation rejected it — the
/// coordinator turns that into a rejected shot instead of a crash, and the
/// reason is logged so the offending settings combination can be fixed.
@interface PhotoCaptureGuard : NSObject
+ (nullable NSError *)capturePhotoWithOutput:(AVCapturePhotoOutput *)output
                                    settings:(AVCapturePhotoSettings *)settings
                                    delegate:(id<AVCapturePhotoCaptureDelegate>)delegate;
@end

NS_ASSUME_NONNULL_END
