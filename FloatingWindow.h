#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@class WebRTCManager;

typedef NS_ENUM(NSInteger, FloatingWindowState) {
    FloatingWindowStateMinimized,
    FloatingWindowStateExpanded
};

@interface FloatingWindow : UIWindow <RTCVideoViewDelegate>

@property (nonatomic, strong, readonly) RTCMTLVideoView *videoView;
@property (nonatomic, strong) WebRTCManager *webRTCManager;
@property (nonatomic, assign) FloatingWindowState windowState;
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) float currentFps;
@property (nonatomic, assign) CGSize lastFrameSize;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *formatInfoLabel;

#pragma mark - Initialization & Lifecycle Methods
- (instancetype)init;
- (void)show;
- (void)hide;
- (void)togglePreview:(UIButton *)sender;
- (void)updateConnectionStatus:(NSString *)status;
- (void)updateFormatInfo:(NSString *)formatInfo;
- (void)updateProcessingMode:(NSString *)processingMode;
- (void)updateIconWithFormatInfo;

@end
