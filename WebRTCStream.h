#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface WebRTCStream : NSObject

+ (instancetype)sharedInstance;
- (void)setActiveStream:(BOOL)active;
- (BOOL)isStreamActive;
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originalBuffer;
- (void)registerPreviewLayer:(AVCaptureVideoPreviewLayer *)layer;

@end
