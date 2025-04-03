#import "WebRTCFrameConverter.h"
#import "logger.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <Accelerate/Accelerate.h>
#import <Metal/Metal.h>

@implementation WebRTCFrameConverter {
    RTCVideoFrame *_lastFrame;
    CGColorSpaceRef _colorSpace;
    dispatch_queue_t _processingQueue;
    BOOL _isReceivingFrames;
    int _frameCount;
    NSTimeInterval _lastFrameTime;
    CIContext *_ciContext;
    CGSize _lastFrameSize;
    IOSPixelFormat _detectedPixelFormat;
    NSString *_processingMode;
    CMVideoDimensions _targetResolution;
    CMTime _targetFrameDuration;
    BOOL _adaptToTargetResolution;
    BOOL _adaptToTargetFrameRate;
    dispatch_semaphore_t _frameProcessingSemaphore;
    OSType _nativeCameraFormat;
    CMVideoDimensions _nativeCameraResolution;
    UIImage *_cachedImage;
    uint64_t _lastFrameHash;
    CMSampleBufferRef _cachedSampleBuffer;
    uint64_t _cachedSampleBufferHash;
    OSType _cachedSampleBufferFormat;
    NSUInteger _totalSampleBuffersCreated;
    NSUInteger _totalSampleBuffersReleased;
    NSUInteger _totalPixelBuffersLocked;
    NSUInteger _totalPixelBuffersUnlocked;
    BOOL _isShuttingDown;
    NSMutableDictionary *_sampleBufferCache;
    NSMutableDictionary *_sampleBufferCacheTimestamps;
    float _currentFps;
    NSUInteger _droppedFrameCount;
}

@synthesize frameCount = _frameCount;
@synthesize detectedPixelFormat = _detectedPixelFormat;
@synthesize processingMode = _processingMode;
@synthesize totalSampleBuffersCreated = _totalSampleBuffersCreated;
@synthesize totalSampleBuffersReleased = _totalSampleBuffersReleased;
@synthesize totalPixelBuffersLocked = _totalPixelBuffersLocked;
@synthesize totalPixelBuffersUnlocked = _totalPixelBuffersUnlocked;
@synthesize currentFps = _currentFps;
@synthesize droppedFrameCount = _droppedFrameCount;

#pragma mark - Inicialização e Cleanup

- (instancetype)init {
    self = [super init];
    if (self) {
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        }];
        
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing", DISPATCH_QUEUE_CONCURRENT);
        _isReceivingFrames = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _lastFrameSize = CGSizeZero;
        _lastFrameHash = 0;
        _detectedPixelFormat = IOSPixelFormatUnknown;
        _processingMode = @"unknown";
        _targetResolution.width = 0;
        _targetResolution.height = 0;
        _targetFrameDuration = CMTimeMake(1, 30);
        _adaptToTargetResolution = NO;
        _adaptToTargetFrameRate = NO;
        _frameProcessingSemaphore = dispatch_semaphore_create(1);
        _nativeCameraFormat = 0;
        _nativeCameraResolution.width = 0;
        _nativeCameraResolution.height = 0;
        _totalSampleBuffersCreated = 0;
        _totalSampleBuffersReleased = 0;
        _totalPixelBuffersLocked = 0;
        _totalPixelBuffersUnlocked = 0;
        _isShuttingDown = NO;
        _sampleBufferCache = [NSMutableDictionary dictionary];
        _sampleBufferCacheTimestamps = [NSMutableDictionary dictionary];
        _activeSampleBuffers = [NSMutableDictionary dictionary];
        _lastProcessedFrameTimestamp = kCMTimeInvalid;
        _captureSessionClock = NULL;
        _droppedFrameCount = 0;
        _currentFps = 0.0f;
        
        [self configureHardwareAcceleration];
        
        writeLog(@"[WebRTCFrameConverter] Inicializado com suporte otimizado para formatos iOS");
    }
    return self;
}

- (void)dealloc {
    _isShuttingDown = YES;
    
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    
    [self clearSampleBufferCache];
    
    NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
    NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
    
    if (sampleBufferDiff > 0 || pixelBufferDiff > 0) {
        writeLog(@"[WebRTCFrameConverter] Corrigindo contadores finais: SampleBuffers=%ld, PixelBuffers=%ld",
                (long)sampleBufferDiff, (long)pixelBufferDiff);
        
        if (sampleBufferDiff > 0) {
            _totalSampleBuffersReleased += sampleBufferDiff;
        }
        if (pixelBufferDiff > 0) {
            _totalPixelBuffersUnlocked += pixelBufferDiff;
        }
    }
    
    _cachedImage = nil;
    writeLog(@"[WebRTCFrameConverter] Objeto desalocado, recursos liberados");
}

#pragma mark - Gestão de Cache e Memória

- (void)clearSampleBufferCache {
    @synchronized(self) {
        NSMutableArray *buffersToRelease = [NSMutableArray array];
        
        if (_cachedSampleBuffer) {
            [buffersToRelease addObject:[NSValue valueWithPointer:_cachedSampleBuffer]];
            _cachedSampleBuffer = NULL;
        }
        
        for (NSValue *value in _sampleBufferCache.allValues) {
            CMSampleBufferRef buffer = NULL;
            [value getValue:&buffer];
            if (buffer) {
                [buffersToRelease addObject:[NSValue valueWithPointer:buffer]];
            }
        }
        
        [_sampleBufferCache removeAllObjects];
        [_sampleBufferCacheTimestamps removeAllObjects];
        
        NSUInteger liberados = 0;
        for (NSValue *value in buffersToRelease) {
            CMSampleBufferRef buffer = NULL;
            [value getValue:&buffer];
            if (buffer) {
                NSNumber *bufferKey = @((intptr_t)buffer);
                [_activeSampleBuffers removeObjectForKey:bufferKey];
                
                CFRelease(buffer);
                _totalSampleBuffersReleased++;
                liberados++;
            }
        }
        
        writeLog(@"[WebRTCFrameConverter] Cache de sample buffers limpo (%lu buffers liberados)", (unsigned long)liberados);
    }
}

- (void)incrementPixelBufferLockCount {
    @synchronized(self) {
        _totalPixelBuffersLocked++;
    }
}

- (void)incrementPixelBufferUnlockCount {
    @synchronized(self) {
        _totalPixelBuffersUnlocked++;
    }
}

- (void)reset {
    dispatch_sync(_processingQueue, ^{
        self->_frameCount = 0;
        self->_lastFrame = nil;
        self->_isReceivingFrames = NO;
        self->_lastFrameTime = 0;
        self->_cachedImage = nil;
        self->_lastFrameHash = 0;
        self->_detectedPixelFormat = IOSPixelFormatUnknown;
        [self clearSampleBufferCache];
        
        writeLog(@"[WebRTCFrameConverter] Reset completo");
    });
}

#pragma mark - Adaptação

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    if (resolution.width == 0 || resolution.height == 0) {
        _adaptToTargetResolution = NO;
        writeLog(@"[WebRTCFrameConverter] Adaptação de resolução desativada");
        return;
    }
    
    _targetResolution = resolution;
    _adaptToTargetResolution = YES;
    _cachedImage = nil;
    [self clearSampleBufferCache];
    
    writeLog(@"[WebRTCFrameConverter] Resolução alvo definida para %dx%d (adaptação ativada)",
           resolution.width, resolution.height);
}

- (void)setTargetFrameRate:(float)frameRate {
    if (frameRate <= 0) {
        _adaptToTargetFrameRate = NO;
        writeLog(@"[WebRTCFrameConverter] Adaptação de taxa de quadros desativada");
        return;
    }
    
    int32_t timeScale = 90000;
    int32_t frameDuration = (int32_t)(timeScale / frameRate);
    _targetFrameDuration = CMTimeMake(frameDuration, timeScale);
    _adaptToTargetFrameRate = YES;
    
    writeLog(@"[WebRTCFrameConverter] Taxa de quadros alvo definida para %.1f fps (adaptação ativada)", frameRate);
}

- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution {
    _nativeCameraFormat = format;
    _nativeCameraResolution = resolution;
    _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:format];
    _cachedImage = nil;
    [self clearSampleBufferCache];
    
    writeLog(@"[WebRTCFrameConverter] Adaptando para formato nativo: %s (%dx%d), IOSPixelFormat: %@",
           [self formatTypeToString:format],
           resolution.width, resolution.height,
           [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat]);
}

#pragma mark - Métodos de classe para tipos de formato

+ (IOSPixelFormat)pixelFormatFromCVFormat:(OSType)cvFormat {
    switch (cvFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return IOSPixelFormat420f;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return IOSPixelFormat420v;
        case kCVPixelFormatType_32BGRA:
            return IOSPixelFormatBGRA;
        default:
            return IOSPixelFormatUnknown;
    }
}

+ (OSType)cvFormatFromPixelFormat:(IOSPixelFormat)iosFormat {
    switch (iosFormat) {
        case IOSPixelFormat420f:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        case IOSPixelFormat420v:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        case IOSPixelFormatBGRA:
            return kCVPixelFormatType_32BGRA;
        default:
            return kCVPixelFormatType_32BGRA;
    }
}

+ (NSString *)stringFromPixelFormat:(IOSPixelFormat)format {
    switch (format) {
        case IOSPixelFormat420f:
            return @"YUV 4:2:0 Full-Range (420f)";
        case IOSPixelFormat420v:
            return @"YUV 4:2:0 Video-Range (420v)";
        case IOSPixelFormatBGRA:
            return @"BGRA 32-bit";
        default:
            return @"Desconhecido";
    }
}

- (const char *)formatTypeToString:(OSType)format {
    char formatStr[5] = {0};
    formatStr[0] = (format >> 24) & 0xFF;
    formatStr[1] = (format >> 16) & 0xFF;
    formatStr[2] = (format >> 8) & 0xFF;
    formatStr[3] = format & 0xFF;
    formatStr[4] = 0;
    
    static char result[5];
    memcpy(result, formatStr, 5);
    return result;
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
    if (CGSizeEqualToSize(_lastFrameSize, size)) {
        return;
    }
    
    writeLog(@"[WebRTCFrameConverter] Tamanho do frame mudou: %@ -> %@",
           NSStringFromCGSize(_lastFrameSize),
           NSStringFromCGSize(size));
    
    _lastFrameSize = size;
    _cachedImage = nil;
    [self clearSampleBufferCache];
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!frame || frame.width == 0 || frame.height == 0) {
        return;
    }
    
    @try {
        if (![self shouldProcessFrame:frame]) {
            return;
        }
        
        uint64_t frameHash = frame.timeStampNs;
        if (frameHash == _lastFrameHash && _cachedImage != nil) {
            if (self.frameCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        self.frameCallback(self->_cachedImage);
                    } @catch (NSException *e) {
                        writeLog(@"[WebRTCFrameConverter] Exceção ao chamar callback: %@", e);
                    }
                });
            }
            return;
        }
        
        _lastFrameHash = frameHash;
        
        @synchronized(self) {
            _frameCount++;
            _isReceivingFrames = YES;
            _lastFrame = frame;
        }
        
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvBuffer = pixelBuffer.pixelBuffer;
            
            if (cvBuffer) {
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvBuffer);
                _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                
                if (CVPixelBufferGetIOSurface(cvBuffer)) {
                    _processingMode = @"hardware-accelerated";
                } else {
                    _processingMode = @"software";
                }
                
                if (_frameCount == 1 || _frameCount % 300 == 0) {
                    char formatChars[5] = {
                        (char)((pixelFormat >> 24) & 0xFF),
                        (char)((pixelFormat >> 16) & 0xFF),
                        (char)((pixelFormat >> 8) & 0xFF),
                        (char)(pixelFormat & 0xFF),
                        0
                    };
                    
                    writeLog(@"[WebRTCFrameConverter] Frame #%d: %dx%d, formato de pixel: %s (IOSPixelFormat: %@), modo: %@",
                          _frameCount,
                          (int)frame.width,
                          (int)frame.height,
                          formatChars,
                          [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat],
                          _processingMode);
                }
            }
        }
        
        if (!self.frameCallback) {
            return;
        }
        
        if (dispatch_semaphore_wait(_frameProcessingSemaphore, DISPATCH_TIME_NOW) != 0) {
            return;
        }
        
        dispatch_async(_processingQueue, ^{
            @autoreleasepool {
                @try {                    
                    if (!frame || frame.width == 0 || frame.height == 0) {
                        dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                        return;
                    }
                    
                    UIImage *image;
                    
                    if (self->_adaptToTargetResolution &&
                        self->_targetResolution.width > 0 &&
                        self->_targetResolution.height > 0) {
                        image = [self adaptedImageFromVideoFrame:frame];
                    } else {
                        image = [self imageFromVideoFrame:frame];
                    }
                    
                    if (image) {
                        self->_cachedImage = image;
                    }
                    
                    // Atualizar taxa de quadros estimada
                    if (self->_frameCount > 1) {
                        NSTimeInterval frameInterval = CACurrentMediaTime() - self->_lastFrameTime;
                        if (frameInterval > 0) {
                            float instantFps = 1.0f / frameInterval;
                            self->_currentFps = self->_currentFps > 0 ?
                                              self->_currentFps * 0.9f + instantFps * 0.1f :
                                              instantFps;
                        }
                    }
                    
                    self->_lastFrameTime = CACurrentMediaTime();
                    
                    if (image) {
                        if (image.size.width > 0 && image.size.height > 0) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                @try {
                                    if (self.frameCallback) {
                                        self.frameCallback(image);
                                    }
                                } @catch (NSException *e) {
                                    writeLog(@"[WebRTCFrameConverter] Exceção ao chamar callback: %@", e);
                                } @finally {
                                    dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                                }
                            });
                        } else {
                            writeLog(@"[WebRTCFrameConverter] Imagem convertida tem tamanho inválido: %@",
                                  NSStringFromCGSize(image.size));
                            dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                        }
                    } else {
                        writeLog(@"[WebRTCFrameConverter] Falha ao converter frame para UIImage");
                        dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                    }
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCFrameConverter] Exceção ao processar frame: %@", exception);
                    dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                }
            }
        });
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCFrameConverter] Exceção externa ao processar frame: %@", exception);
        dispatch_semaphore_signal(_frameProcessingSemaphore);
    }
}

- (void)setRenderFrame:(RTCVideoFrame *)frame {
    [self renderFrame:frame];
}

#pragma mark - Conversão de Frame

- (UIImage *)imageFromVideoFrame:(RTCVideoFrame *)frame {
    @autoreleasepool {
        @try {
            if (!frame) {
                return nil;
            }
            
            id<RTCVideoFrameBuffer> buffer = frame.buffer;
            if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
                RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
                CVPixelBufferRef cvPixelBuffer = pixelBuffer.pixelBuffer;
                
                if (!cvPixelBuffer) {
                    return nil;
                }
                
                size_t width = CVPixelBufferGetWidth(cvPixelBuffer);
                size_t height = CVPixelBufferGetHeight(cvPixelBuffer);
                
                if (width == 0 || height == 0) {
                    return nil;
                }
                
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvPixelBuffer);
                IOSPixelFormat iosFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                
                // Bloquear buffer para acesso
                CVPixelBufferLockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                self.totalPixelBuffersLocked++;
                
                UIImage *image = nil;
                
                @try {
                    if (iosFormat == IOSPixelFormat420f || iosFormat == IOSPixelFormat420v) {
                        // Converter YUV para RGB
                        CVPixelBufferRef rgbBuffer = [self convertYUVToRGBWithCIImage:cvPixelBuffer];
                        
                        if (rgbBuffer) {
                            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(rgbBuffer);
                            size_t rgbWidth = CVPixelBufferGetWidth(rgbBuffer);
                            size_t rgbHeight = CVPixelBufferGetHeight(rgbBuffer);
                            
                            CVPixelBufferLockBaseAddress(rgbBuffer, kCVPixelBufferLock_ReadOnly);
                            self.totalPixelBuffersLocked++;
                            
                            void *baseAddress = CVPixelBufferGetBaseAddress(rgbBuffer);
                            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                            
                            CGContextRef cgContext = CGBitmapContextCreate(baseAddress,
                                                                         rgbWidth,
                                                                         rgbHeight,
                                                                         8,
                                                                         bytesPerRow,
                                                                         colorSpace,
                                                                         kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                            
                            CGColorSpaceRelease(colorSpace);
                            
                            if (cgContext) {
                                CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);
                                CGContextRelease(cgContext);
                                
                                if (cgImage) {
                                    if (frame.rotation != RTCVideoRotation_0) {
                                        UIImage *originalImage = [UIImage imageWithCGImage:cgImage];
                                        CGImageRelease(cgImage);
                                        image = [self rotateImage:originalImage withRotation:frame.rotation];
                                    } else {
                                        image = [UIImage imageWithCGImage:cgImage];
                                        CGImageRelease(cgImage);
                                    }
                                }
                            }
                            
                            CVPixelBufferUnlockBaseAddress(rgbBuffer, kCVPixelBufferLock_ReadOnly);
                            self.totalPixelBuffersUnlocked++;
                            CVPixelBufferRelease(rgbBuffer);
                        }
                    }
                    else if (iosFormat == IOSPixelFormatBGRA) {
                        // Format já é BGRA, apenas criar imagem
                        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(cvPixelBuffer);
                        void *baseAddress = CVPixelBufferGetBaseAddress(cvPixelBuffer);
                        
                        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                        CGContextRef cgContext = CGBitmapContextCreate(baseAddress,
                                                                     width,
                                                                     height,
                                                                     8,
                                                                     bytesPerRow,
                                                                     colorSpace,
                                                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                        
                        CGColorSpaceRelease(colorSpace);
                        
                        if (cgContext) {
                            CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);
                            CGContextRelease(cgContext);
                            
                            if (cgImage) {
                                if (frame.rotation != RTCVideoRotation_0) {
                                    UIImage *originalImage = [UIImage imageWithCGImage:cgImage];
                                    CGImageRelease(cgImage);
                                    image = [self rotateImage:originalImage withRotation:frame.rotation];
                                } else {
                                    image = [UIImage imageWithCGImage:cgImage];
                                    CGImageRelease(cgImage);
                                }
                            }
                        }
                    }
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCFrameConverter] Exceção ao processar imagem: %@", exception);
                }
                
                CVPixelBufferUnlockBaseAddress(cvPixelBuffer, kCVPixelBufferLock_ReadOnly);
                self.totalPixelBuffersUnlocked++;
                
                return image;
            } else {
                writeLog(@"[WebRTCFrameConverter] Tipo de buffer não suportado: %@", NSStringFromClass([buffer class]));
                return nil;
            }
        } @catch (NSException *e) {
            writeLog(@"[WebRTCFrameConverter] Exceção ao converter frame para UIImage: %@", e);
            return nil;
        }
    }
}

- (UIImage *)rotateImage:(UIImage *)image withRotation:(RTCVideoRotation)rotation {
    if (!image) return nil;
    
    UIGraphicsBeginImageContextWithOptions(
        rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270 ?
            CGSizeMake(image.size.height, image.size.width) :
            image.size,
        NO,
        image.scale
    );
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    switch (rotation) {
        case RTCVideoRotation_90:
            CGContextTranslateCTM(context, 0, image.size.height);
            CGContextRotateCTM(context, -M_PI_2);
            CGContextDrawImage(context, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
            break;
        case RTCVideoRotation_180:
            CGContextTranslateCTM(context, image.size.width, image.size.height);
            CGContextRotateCTM(context, M_PI);
            CGContextDrawImage(context, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
            break;
        case RTCVideoRotation_270:
            CGContextTranslateCTM(context, image.size.width, 0);
            CGContextRotateCTM(context, M_PI_2);
            CGContextDrawImage(context, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
            break;
        default:
            return image;
    }
    
    UIImage *rotatedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return rotatedImage ?: image;
}

- (CVPixelBufferRef)convertYUVToRGBWithCIImage:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NULL;
    
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ciImage) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do buffer YUV");
        return NULL;
    }
    
    CVPixelBufferRef outputBuffer = NULL;
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    NSDictionary* attributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @(width),
        (NSString*)kCVPixelBufferHeightKey: @(height),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)attributes,
                                         &outputBuffer);
    
    if (result != kCVReturnSuccess || !outputBuffer) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar buffer de saída: %d", result);
        return NULL;
    }
    
    [_ciContext render:ciImage toCVPixelBuffer:outputBuffer];
    _processingMode = @"software-ciimage";
    
    return outputBuffer;
}

- (BOOL)configureHardwareAcceleration {
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    BOOL metalSupported = (metalDevice != nil);
    
    if (metalDevice) {
        writeLog(@"[WebRTCFrameConverter] Metal disponível: %@", [metalDevice name]);
    }
    
    if (_ciContext) {
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        };
        _ciContext = [CIContext contextWithOptions:options];
    }
    
    if (metalSupported) {
        _processingMode = @"hardware-accelerated";
    } else {
        _processingMode = @"software";
    }
    
    writeLog(@"[WebRTCFrameConverter] Modo de processamento: %@", _processingMode);
    return (metalSupported && _ciContext != nil);
}

#pragma mark - Imagem Adaptada

- (UIImage *)adaptedImageFromVideoFrame:(RTCVideoFrame *)frame {
    @autoreleasepool {
        UIImage *originalImage = [self imageFromVideoFrame:frame];
        if (!originalImage) return nil;
        
        if ((int)originalImage.size.width == _targetResolution.width &&
            (int)originalImage.size.height == _targetResolution.height) {
            return originalImage;
        }
        
        float originalAspect = originalImage.size.width / originalImage.size.height;
        float targetAspect = (float)_targetResolution.width / (float)_targetResolution.height;
        
        CGRect drawRect;
        CGSize finalSize = CGSizeMake(_targetResolution.width, _targetResolution.height);
        
        if (fabs(originalAspect - targetAspect) < 0.01) {
            drawRect = CGRectMake(0, 0, finalSize.width, finalSize.height);
        }
        else if (originalAspect > targetAspect) {
            float scaledHeight = finalSize.height;
            float scaledWidth = scaledHeight * originalAspect;
            float xOffset = (scaledWidth - finalSize.width) / 2.0f;
            drawRect = CGRectMake(-xOffset, 0, scaledWidth, scaledHeight);
        }
        else {
            float scaledWidth = finalSize.width;
            float scaledHeight = scaledWidth / originalAspect;
            float yOffset = (scaledHeight - finalSize.height) / 2.0f;
            drawRect = CGRectMake(0, -yOffset, scaledWidth, scaledHeight);
        }
        
        UIGraphicsBeginImageContextWithOptions(finalSize, NO, 1.0);
        [[UIColor blackColor] setFill];
        UIRectFill(CGRectMake(0, 0, finalSize.width, finalSize.height));
        [originalImage drawInRect:drawRect];
        
        UIImage *adaptedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (!adaptedImage) {
            return originalImage;
        }
        
        return adaptedImage;
    }
}

#pragma mark - Sample Buffer

- (CMSampleBufferRef)getLatestSampleBufferWithFormat:(IOSPixelFormat)pixelFormat {
    @try {
        if (!_lastFrame) {
            return NULL;
        }
        
        CMTime frameTimestamp = CMTimeMake(_lastFrame.timeStampNs, 1000000000);
        if ([self shouldDropFrameWithTimestamp:frameTimestamp]) {
            return NULL;
        }
        
        OSType cvFormat = [WebRTCFrameConverter cvFormatFromPixelFormat:pixelFormat];
        NSNumber *formatKey = @(cvFormat);
        
        @synchronized(self) {
            if (_cachedSampleBuffer && _cachedSampleBufferHash == _lastFrameHash && _cachedSampleBufferFormat == cvFormat) {
                CMSampleBufferRef outputBuffer = NULL;
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, _cachedSampleBuffer, &outputBuffer);
                if (status != noErr) {
                    writeLog(@"[WebRTCFrameConverter] Erro ao criar cópia do CMSampleBuffer: %d", (int)status);
                    return NULL;
                }
                return outputBuffer;
            }
            
            NSValue *cachedBufferValue = _sampleBufferCache[formatKey];
            if (cachedBufferValue) {
                CMSampleBufferRef cachedBuffer = NULL;
                [cachedBufferValue getValue:&cachedBuffer];
                if (cachedBuffer) {
                    CMSampleBufferRef outputBuffer = NULL;
                    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, cachedBuffer, &outputBuffer);
                    if (status == noErr) {
                        return outputBuffer;
                    }
                }
            }
        }
        
        CMSampleBufferRef sampleBuffer = [self createSampleBufferWithFormat:cvFormat];
        
        if (sampleBuffer) {
            @synchronized(self) {
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &_cachedSampleBuffer);
                if (status == noErr) {
                    _cachedSampleBufferHash = _lastFrameHash;
                    _cachedSampleBufferFormat = cvFormat;
                    
                    CMSampleBufferRef formatCacheBuffer = NULL;
                    status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &formatCacheBuffer);
                    if (status == noErr && formatCacheBuffer) {
                        NSValue *oldValue = _sampleBufferCache[formatKey];
                        if (oldValue) {
                            CMSampleBufferRef oldBuffer = NULL;
                            [oldValue getValue:&oldBuffer];
                            if (oldBuffer) {
                                CFRelease(oldBuffer);
                                _totalSampleBuffersReleased++;
                                [_activeSampleBuffers removeObjectForKey:@(CFHash(oldBuffer))];
                            }
                        }
                        
                        NSValue *newValue = [NSValue valueWithBytes:&formatCacheBuffer objCType:@encode(CMSampleBufferRef)];
                        _sampleBufferCache[formatKey] = newValue;
                        _sampleBufferCacheTimestamps[formatKey] = [NSDate date];
                        
                        _activeSampleBuffers[@(CFHash(formatCacheBuffer))] = @YES;
                    }
                }
            }
        }
        
        return sampleBuffer;
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCFrameConverter] Exceção em getLatestSampleBufferWithFormat: %@", exception);
        return NULL;
    }
}

- (CMSampleBufferRef)getLatestSampleBuffer {
    return [self getLatestSampleBufferWithFormat:_detectedPixelFormat];
}

- (CMSampleBufferRef)createSampleBufferWithFormat:(OSType)format {
    if (!_lastFrame) return NULL;
    
    id<RTCVideoFrameBuffer> buffer = _lastFrame.buffer;
    if (![buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        return NULL;
    }
    
    RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)buffer;
    CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
    
    if (!pixelBuffer) {
        return NULL;
    }
    
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    
    if (sourceFormat == format) {
        return [self createSampleBufferFromPixelBuffer:pixelBuffer];
    }
    
    CVPixelBufferRef convertedBuffer = NULL;
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(format),
        (NSString *)kCVPixelBufferWidthKey: @(CVPixelBufferGetWidth(pixelBuffer)),
        (NSString *)kCVPixelBufferHeightKey: @(CVPixelBufferGetHeight(pixelBuffer)),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                          CVPixelBufferGetWidth(pixelBuffer),
                                          CVPixelBufferGetHeight(pixelBuffer),
                                          format,
                                          (__bridge CFDictionaryRef)pixelBufferAttributes,
                                          &convertedBuffer);
    
    if (result != kCVReturnSuccess || !convertedBuffer) {
        return NULL;
    }
    
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    [_ciContext render:ciImage toCVPixelBuffer:convertedBuffer];
    
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:convertedBuffer];
    CVPixelBufferRelease(convertedBuffer);
    
    _totalSampleBuffersCreated++;
    
    if (sampleBuffer) {
        @synchronized(self) {
            NSNumber *bufferKey = @(CFHash(sampleBuffer));
            _activeSampleBuffers[bufferKey] = @YES;
        }
    }
    
    return sampleBuffer;
}

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NULL;
    
    _totalSampleBuffersCreated++;
    
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    if (status != 0) {
        return NULL;
    }
    
    CMTimeScale timeScale = 1000000000; // Nanosegundos
    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    
    if (_lastFrame) {
        uint64_t rtcTimestampNs = _lastFrame.timeStampNs;
        if (rtcTimestampNs > 0) {
            hostTime = CMTimeMake(rtcTimestampNs, timeScale);
        }
    }
    
    CMSampleTimingInfo timingInfo;
    Float64 frameDuration = 1.0 / 30.0; // Default: 30fps
    
    if (_adaptToTargetFrameRate && CMTIME_IS_VALID(_targetFrameDuration)) {
        frameDuration = CMTimeGetSeconds(_targetFrameDuration);
    } else if (_currentFps > 0) {
        frameDuration = 1.0 / _currentFps;
    }
    
    timingInfo.duration = CMTimeMakeWithSeconds(frameDuration, timeScale);
    timingInfo.presentationTimeStamp = hostTime;
    timingInfo.decodeTimeStamp = kCMTimeInvalid;
    
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true,
        NULL,
        NULL,
        formatDescription,
        &timingInfo,
        &sampleBuffer
    );
    
    if (formatDescription) {
        CFRelease(formatDescription);
    }
    
    if (status != 0) {
        return NULL;
    }
    
    if (sampleBuffer) {
        @synchronized(self) {
            NSNumber *bufferKey = @(CFHash(sampleBuffer));
            _activeSampleBuffers[bufferKey] = @{
                @"timestamp": [NSDate date],
                @"ptsSeconds": @(CMTimeGetSeconds(timingInfo.presentationTimeStamp)),
                @"durationSeconds": @(CMTimeGetSeconds(timingInfo.duration))
            };
            _lastBufferTimestamp = timingInfo.presentationTimeStamp;
        }
    }
    
    return sampleBuffer;
}

- (BOOL)shouldDropFrameWithTimestamp:(CMTime)frameTimestamp {
    if (!_adaptToTargetFrameRate) return NO;
    
    if (CMTIME_IS_INVALID(_lastProcessedFrameTimestamp)) {
        _lastProcessedFrameTimestamp = frameTimestamp;
        return NO;
    }
    
    CMTime targetFrameDuration = _targetFrameDuration;
    if (CMTIME_IS_INVALID(targetFrameDuration) || CMTIME_COMPARE_INLINE(targetFrameDuration, ==, kCMTimeZero)) {
        targetFrameDuration = CMTimeMake(1, 30);
    }
    
    CMTime elapsed = CMTimeSubtract(frameTimestamp, _lastProcessedFrameTimestamp);
    if (CMTIME_IS_VALID(elapsed) && CMTIME_COMPARE_INLINE(elapsed, <, targetFrameDuration)) {
        Float64 elapsedSeconds = CMTimeGetSeconds(elapsed);
        Float64 targetSeconds = CMTimeGetSeconds(targetFrameDuration);
        
        if (targetSeconds > 0) {
            Float64 percentOfTarget = elapsedSeconds / targetSeconds;
            if (percentOfTarget < 0.7) {
                _droppedFrameCount++;
                return YES;
            }
        }
    }
    
    _lastProcessedFrameTimestamp = frameTimestamp;
    return NO;
}

- (UIImage *)getLastFrameAsImage {
    @synchronized(self) {
        if (!_lastFrame) {
            return nil;
        }
        
        if (_cachedImage) {
            return _cachedImage;
        }
        
        if (_adaptToTargetResolution && _targetResolution.width > 0 && _targetResolution.height > 0) {
            return [self adaptedImageFromVideoFrame:_lastFrame];
        } else {
            return [self imageFromVideoFrame:_lastFrame];
        }
    }
}

- (float)getEstimatedFps {
    return _currentFps;
}

- (BOOL)shouldProcessFrame:(RTCVideoFrame *)frame {
    if (!_lastFrame) {
        return YES;
    }
    
    uint64_t currentTime = frame.timeStampNs;
    uint64_t lastTime = _lastFrame.timeStampNs;
    
    if (currentTime <= lastTime) {
        return YES;
    }
    
    uint64_t timeDiff = currentTime - lastTime;
    float fpsCurrent = 1000000000.0f / timeDiff; // ns para segundos
    float targetFps = _targetFrameDuration.timescale / (float)_targetFrameDuration.value;
    
    if (fpsCurrent <= targetFps) {
        return YES;
    }
    
    static uint64_t frameCounter = 0;
    frameCounter++;
    
    int dropRatio = (int)(fpsCurrent / targetFps);
    BOOL shouldDrop = (frameCounter % dropRatio != 0);
    
    if (shouldDrop) {
        _droppedFrameCount++;
    }
    
    return !shouldDrop;
}

@end
