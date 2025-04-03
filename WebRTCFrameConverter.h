#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, IOSPixelFormat) {
    IOSPixelFormatUnknown = 0,
    IOSPixelFormat420f,
    IOSPixelFormat420v,
    IOSPixelFormatBGRA
};

@interface WebRTCFrameConverter : NSObject <RTCVideoRenderer>

@property (nonatomic, copy) void (^frameCallback)(UIImage *image);
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;
@property (nonatomic, assign, readonly) int frameCount;
@property (nonatomic, assign, readonly) IOSPixelFormat detectedPixelFormat;
@property (nonatomic, copy, readonly) NSString *processingMode;
@property (nonatomic, assign, readonly) NSUInteger totalSampleBuffersCreated;
@property (nonatomic, assign, readonly) NSUInteger totalSampleBuffersReleased;
@property (nonatomic, assign) NSUInteger totalPixelBuffersLocked;
@property (nonatomic, assign) NSUInteger totalPixelBuffersUnlocked;
@property (nonatomic, assign) float currentFps;
@property (nonatomic, assign) NSUInteger droppedFrameCount;
@property (nonatomic, strong) NSMutableDictionary *activeSampleBuffers;
@property (nonatomic, assign) CMClockRef captureSessionClock;
@property (nonatomic, assign) CMTime lastProcessedFrameTimestamp;
@property (nonatomic, assign) CMTime lastBufferTimestamp;

- (instancetype)init;
- (void)incrementPixelBufferLockCount;
- (void)incrementPixelBufferUnlockCount;
- (void)reset;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (CMSampleBufferRef)getLatestSampleBufferWithFormat:(IOSPixelFormat)pixelFormat;
- (UIImage *)getLastFrameAsImage;
- (void)setTargetResolution:(CMVideoDimensions)resolution;
- (void)setTargetFrameRate:(float)frameRate;
- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution;
- (void)clearSampleBufferCache;
- (float)getEstimatedFps;

+ (IOSPixelFormat)pixelFormatFromCVFormat:(OSType)cvFormat;
+ (OSType)cvFormatFromPixelFormat:(IOSPixelFormat)iosFormat;
+ (NSString *)stringFromPixelFormat:(IOSPixelFormat)format;

@end
