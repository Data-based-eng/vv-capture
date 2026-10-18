#import "PhotoCaptureGuard.h"

@implementation PhotoCaptureGuard

+ (nullable NSError *)capturePhotoWithOutput:(AVCapturePhotoOutput *)output
                                    settings:(AVCapturePhotoSettings *)settings
                                    delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    @try {
        [output capturePhotoWithSettings:settings delegate:delegate];
        return nil;
    } @catch (NSException *exception) {
        NSString *detail = [NSString stringWithFormat:@"%@: %@",
                            exception.name, exception.reason ?: @"(no reason given)"];
        return [NSError errorWithDomain:@"com.visionvend.capture.photo"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: detail}];
    }
}

@end
