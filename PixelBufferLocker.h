#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@class WebRTCFrameConverter;

@interface PixelBufferLocker : NSObject

@property (nonatomic, assign, readonly) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign, readonly) BOOL locked;
@property (nonatomic, weak, readonly) WebRTCFrameConverter *converter;

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          converter:(WebRTCFrameConverter *)converter;
- (BOOL)lock;
- (void)unlock;

@end
