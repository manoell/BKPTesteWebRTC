#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>
#import "WebRTCFrameConverter.h"

@class FloatingWindow;

typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,
    WebRTCManagerStateConnecting,
    WebRTCManagerStateConnected,
    WebRTCManagerStateError,
    WebRTCManagerStateReconnecting
};
typedef NS_ENUM(NSInteger, WebRTCAdaptationMode) {
    WebRTCAdaptationModeAuto,
    WebRTCAdaptationModePerformance,
    WebRTCAdaptationModeQuality,
    WebRTCAdaptationModeCompatibility
};

@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

@property (nonatomic, weak) FloatingWindow *floatingWindow;
@property (nonatomic, assign, readonly) WebRTCManagerState state;
@property (nonatomic, strong) NSString *serverIP;
@property (nonatomic, strong, readonly) WebRTCFrameConverter *frameConverter;
@property (nonatomic, assign) WebRTCAdaptationMode adaptationMode;
@property (nonatomic, assign) BOOL autoAdaptToCameraEnabled;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, strong) NSTimer *reconnectionTimer;
@property (nonatomic, assign) int reconnectionAttempts;
@property (nonatomic, assign) BOOL isReconnecting;
@property (nonatomic, strong) dispatch_source_t resourceMonitorTimer;
@property (nonatomic, strong) NSTimer *statsInterval;
@property (nonatomic, strong) NSTimer *keepAliveInterval;
@property (nonatomic, strong) NSURLSessionWebSocketTask *ws;

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;
- (void)startWebRTC;
- (void)stopWebRTC:(BOOL)userInitiated;
- (void)sendByeMessage;
- (NSDictionary *)getConnectionStats;
- (void)removeRendererFromVideoTrack:(id<RTCVideoRenderer>)renderer;
- (float)getEstimatedFps;
- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position;
- (void)setTargetResolution:(CMVideoDimensions)resolution;
- (void)setTargetFrameRate:(float)frameRate;
- (CMSampleBufferRef)getLatestVideoSampleBuffer;
- (CMSampleBufferRef)getLatestVideoSampleBufferWithFormat:(IOSPixelFormat)format;
- (void)setIOSCompatibilitySignaling:(BOOL)enable;

@end

#endif /* WEBRTCMANAGER_H */
