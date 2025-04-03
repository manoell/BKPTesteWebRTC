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
@property (nonatomic, strong, readonly) NSMutableDictionary *activeSampleBuffers;
@property (nonatomic, strong, readonly) NSMutableDictionary *sampleBufferCacheTimestamps;
@property (nonatomic, strong) dispatch_source_t resourceMonitorTimer;

- (void)incrementPixelBufferLockCount;
- (void)incrementPixelBufferUnlockCount;
- (void)forceReleaseAllSampleBuffers;
- (instancetype)init;
- (void)setRenderFrame:(RTCVideoFrame *)frame;
- (CMSampleBufferRef)getLatestSampleBufferWithFormat:(IOSPixelFormat)pixelFormat;
- (CMSampleBufferRef)getLatestSampleBuffer;
- (CMSampleBufferRef)createSampleBufferWithFormat:(OSType)format;
- (UIImage *)getLastFrameAsImage;
- (NSDictionary *)getFrameProcessingStats;
- (void)setTargetResolution:(CMVideoDimensions)resolution;
- (void)setTargetFrameRate:(float)frameRate;
- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution;
+ (IOSPixelFormat)pixelFormatFromCVFormat:(OSType)cvFormat;
+ (OSType)cvFormatFromPixelFormat:(IOSPixelFormat)iosFormat;
+ (NSString *)stringFromPixelFormat:(IOSPixelFormat)format;
- (void)reset;
- (void)performSafeCleanup;
- (void)releaseSampleBuffer:(CMSampleBufferRef)buffer;
- (void)checkForResourceLeaks;
- (void)startResourceMonitoring;
- (void)optimizeCacheSystem;
- (void)clearSampleBufferCache;

@property (nonatomic, assign) CMClockRef captureSessionClock;
@property (nonatomic, assign) CMTime lastProcessedFrameTimestamp;
@property (nonatomic, assign) CMTime lastBufferTimestamp;
@property (nonatomic, assign) NSUInteger droppedFrameCount;
@property (nonatomic, assign) float currentFps;
- (BOOL)shouldDropFrameWithTimestamp:(CMTime)frameTimestamp;
- (CMSampleBufferRef)enhanceSampleBufferTiming:(CMSampleBufferRef)sampleBuffer
                         preserveOriginalTiming:(BOOL)preserveOriginalTiming;
- (CMClockRef)getCurrentSyncClock;
- (void)setCaptureSessionClock:(CMClockRef)clock;
- (NSDictionary *)extractMetadataFromSampleBuffer:(CMSampleBufferRef)originalBuffer;
- (BOOL)applyMetadataToSampleBuffer:(CMSampleBufferRef)sampleBuffer metadata:(NSDictionary *)metadata;
- (CVPixelBufferRef)convertYUVToRGBWithHardwareAcceleration:(CVPixelBufferRef)pixelBuffer;
- (BOOL)isHardwareAccelerationAvailable;
- (BOOL)setupColorConversionContextFromFormat:(OSType)sourceFormat toFormat:(OSType)destFormat;
- (BOOL)configureHardwareAcceleration;
- (void)optimizeForPerformance:(BOOL)optimize;
- (RTCCVPixelBuffer *)scalePixelBufferToTargetSize:(RTCCVPixelBuffer *)pixelBuffer;
- (void)setFrameRateAdaptationStrategy:(NSString *)newStrategy;
- (BOOL)shouldProcessFrame:(RTCVideoFrame *)frame;

@end
