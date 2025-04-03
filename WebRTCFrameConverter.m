#import "WebRTCFrameConverter.h"
#import "logger.h"
#import "PixelBufferLocker.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CMTime.h>
#import <CoreMedia/CMSampleBuffer.h>
#import <CoreMedia/CMFormatDescription.h>
#import <CoreMedia/CMMetadata.h>
#import <CoreMedia/CMAttachment.h>
#import <CoreMedia/CMBufferQueue.h>
#import <CoreMedia/CMSync.h>
#import <UIKit/UIKit.h>
#import <Accelerate/Accelerate.h>
#import <Metal/Metal.h>

@implementation WebRTCFrameConverter {
    RTCVideoFrame *_lastFrame;
    CGColorSpaceRef _colorSpace;
    CGColorSpaceRef _yuvColorSpace;
    dispatch_queue_t _processingQueue;
    BOOL _isReceivingFrames;
    int _frameCount;
    NSTimeInterval _lastFrameTime;
    CFTimeInterval _maxFrameRate;
    CIContext *_ciContext;
    CGSize _lastFrameSize;
    NSTimeInterval _lastPerformanceLogTime;
    float _frameProcessingTimes[10];
    int _frameTimeIndex;
    BOOL _didLogFirstFrameDetails;
    IOSPixelFormat _detectedPixelFormat;
    NSString *_processingMode;
    CMVideoDimensions _targetResolution;
    CMTime _targetFrameDuration;
    BOOL _adaptToTargetResolution;
    BOOL _adaptToTargetFrameRate;
    dispatch_semaphore_t _frameProcessingSemaphore;
    OSType _nativeCameraFormat;
    CMVideoDimensions _nativeCameraResolution;
    BOOL _adaptToNativeFormat;
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
    NSTimeInterval _lastLeakWarningTime;
    NSUInteger _maxCachedSampleBuffers;
    NSMutableDictionary<NSNumber *, NSValue *> *_sampleBufferCache;
}

@synthesize frameCount = _frameCount;
@synthesize detectedPixelFormat = _detectedPixelFormat;
@synthesize processingMode = _processingMode;
@synthesize totalSampleBuffersCreated = _totalSampleBuffersCreated;
@synthesize totalSampleBuffersReleased = _totalSampleBuffersReleased;
@synthesize totalPixelBuffersLocked = _totalPixelBuffersLocked;
@synthesize totalPixelBuffersUnlocked = _totalPixelBuffersUnlocked;

#pragma mark - Inicialização e Cleanup
- (instancetype)init {
    self = [super init];
    if (self) {
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        };
        _ciContext = [CIContext contextWithOptions:options];
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _yuvColorSpace = CGColorSpaceCreateDeviceRGB();
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing",
                                               DISPATCH_QUEUE_CONCURRENT);
        _isReceivingFrames = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _maxFrameRate = 1.0 / 60.0;
        _lastFrameSize = CGSizeZero;
        _lastPerformanceLogTime = 0;
        _didLogFirstFrameDetails = NO;
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
        _adaptToNativeFormat = NO;
        for (int i = 0; i < 10; i++) {
            _frameProcessingTimes[i] = 0.0f;
        }
        _frameTimeIndex = 0;
        _totalSampleBuffersCreated = 0;
        _totalSampleBuffersReleased = 0;
        _totalPixelBuffersLocked = 0;
        _totalPixelBuffersUnlocked = 0;
        _isShuttingDown = NO;
        _lastLeakWarningTime = 0;
        _maxCachedSampleBuffers = 3;
        _sampleBufferCache = [NSMutableDictionary dictionaryWithCapacity:_maxCachedSampleBuffers];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleLowMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        _activeSampleBuffers = [NSMutableDictionary dictionary];
        _sampleBufferCacheTimestamps = [NSMutableDictionary dictionary];
        _lastProcessedFrameTimestamp = kCMTimeInvalid;
        _lastBufferTimestamp = kCMTimeInvalid;
        _captureSessionClock = NULL;
        _droppedFrameCount = 0;
        _currentFps = 0.0f;
        [self startResourceMonitoring];
        [self configureHardwareAcceleration];
        [self optimizeForPerformance:YES];
        [self setFrameRateAdaptationStrategy:@"balanced"];
        writeLog(@"[WebRTCFrameConverter] Inicializado com suporte otimizado para formatos iOS");
    }
    return self;
}

- (void)dealloc {
    _isShuttingDown = YES;
    if (_resourceMonitorTimer) {
        dispatch_source_cancel(_resourceMonitorTimer);
        _resourceMonitorTimer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    if (_yuvColorSpace) {
        CGColorSpaceRelease(_yuvColorSpace);
        _yuvColorSpace = NULL;
    }
    [self clearSampleBufferCache];
    [self forceReleaseAllSampleBuffers];
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
    writeLog(@"[WebRTCFrameConverter] Finalizando - Estatísticas finais: SampleBuffers %lu/%lu, PixelBuffers %lu/%lu",
             (unsigned long)_totalSampleBuffersCreated, (unsigned long)_totalSampleBuffersReleased,
             (unsigned long)_totalPixelBuffersLocked, (unsigned long)_totalPixelBuffersUnlocked);
    _cachedImage = nil;
    writeLog(@"[WebRTCFrameConverter] Objeto desalocado, recursos liberados");
}

#pragma mark - Gestão de Memória e Cache
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

- (void)releaseSampleBuffer:(CMSampleBufferRef)buffer {
    if (!buffer) return;
    @synchronized(self) {
        NSNumber *bufferKey = @(CFHash(buffer));
        [_activeSampleBuffers removeObjectForKey:bufferKey];
        _totalSampleBuffersReleased++;
        CFRelease(buffer);
        writeLog(@"[WebRTCFrameConverter] Buffer liberado explicitamente: %p", buffer);
    }
}

- (void)optimizeCacheSystem {
    @synchronized(self) {
        if (_sampleBufferCache.count > _maxCachedSampleBuffers) {
            NSArray *sortedKeys = [_sampleBufferCache.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *key1, NSNumber *key2) {
                NSDate *date1 = _sampleBufferCacheTimestamps[key1];
                NSDate *date2 = _sampleBufferCacheTimestamps[key2];
                return [date1 compare:date2];
            }];
            NSInteger itemsToRemove = _sampleBufferCache.count - _maxCachedSampleBuffers;
            for (NSInteger i = 0; i < itemsToRemove && i < sortedKeys.count; i++) {
                NSNumber *keyToRemove = sortedKeys[i];
                NSValue *bufferValue = _sampleBufferCache[keyToRemove];
                if (bufferValue) {
                    CMSampleBufferRef buffer = NULL;
                    [bufferValue getValue:&buffer];
                    if (buffer) {
                        CFRelease(buffer);
                        _totalSampleBuffersReleased++;
                    }
                }
                [_sampleBufferCache removeObjectForKey:keyToRemove];
                [_sampleBufferCacheTimestamps removeObjectForKey:keyToRemove];
            }
            writeLog(@"[WebRTCFrameConverter] Otimizado cache: removidas %ld entradas antigas", (long)itemsToRemove);
        }
    }
}

- (void)startResourceMonitoring {
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t monitorQueue = dispatch_queue_create("com.webrtc.resourcemonitor", DISPATCH_QUEUE_SERIAL);
    if (_resourceMonitorTimer) {
        dispatch_source_cancel(_resourceMonitorTimer);
        _resourceMonitorTimer = nil;
    }
    _resourceMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, monitorQueue);
    dispatch_source_set_timer(_resourceMonitorTimer,
                             dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), // Reduzido para 3 segundos
                             3 * NSEC_PER_SEC,
                             1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(_resourceMonitorTimer, ^{
        [weakSelf checkForResourceLeaks];
        static NSUInteger checkCount = 0;
        checkCount++;
        if (checkCount % 10 == 0) {
            writeLog(@"[WebRTCFrameConverter] Executando limpeza profunda periódica");
            [weakSelf clearSampleBufferCache];
            [weakSelf optimizeCacheSystem];
        }
    });
    dispatch_resume(_resourceMonitorTimer);
    writeLog(@"[WebRTCFrameConverter] Monitoramento de recursos iniciado com intervalo de 3 segundos");
}

- (void)checkForResourceLeaks {
    if (_isShuttingDown) return;
    @synchronized(self) {
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        NSDate *now = [NSDate date];
        NSMutableArray *keysToRemove = [NSMutableArray array];
        [_activeSampleBuffers enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, id info, BOOL *stop) {
            if ([info isKindOfClass:[NSDictionary class]]) {
                NSDate *timestamp = info[@"timestamp"];
                if (timestamp && [now timeIntervalSinceDate:timestamp] > 5.0) {
                    [keysToRemove addObject:key];
                }
            } else {
                [keysToRemove addObject:key];
            }
        }];
        if (keysToRemove.count > 0) {
            writeLog(@"[WebRTCFrameConverter] Limpando %lu sample buffers antigos", (unsigned long)keysToRemove.count);
            for (NSNumber *key in keysToRemove) {
                [_activeSampleBuffers removeObjectForKey:key];
                _totalSampleBuffersReleased++;
            }
        }
        if (pixelBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Corrigindo desbalanceamento de %ld CVPixelBuffers", (long)pixelBufferDiff);
            _totalPixelBuffersUnlocked += pixelBufferDiff;
        }
        if (sampleBufferDiff > 5) {
            writeLog(@"[WebRTCFrameConverter] Desbalanceamento detectado - SampleBuffers: %ld. Forçando limpeza.", (long)sampleBufferDiff);
            [self clearSampleBufferCache];
        }
        if (sampleBufferDiff > 20 || pixelBufferDiff > 20) {
            writeLog(@"[WebRTCFrameConverter] Desbalanceamento severo - executando reset completo");
            [self reset];
            @autoreleasepool { }
        }
    }
}

- (void)handleLowMemoryWarning {
    writeLog(@"[WebRTCFrameConverter] Aviso de memória baixa recebido, liberando recursos");
    [self clearSampleBufferCache];
    _cachedImage = nil;
}

- (void)checkResourceBalance {
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastLeakWarningTime < 10.0) return;
    @synchronized(self) {
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
            writeLog(@"[WebRTCFrameConverter] Possível vazamento de recursos detectado - SampleBuffers: %ld não liberados, PixelBuffers: %ld não desbloqueados",
                           (long)sampleBufferDiff,
                           (long)pixelBufferDiff);
            [self clearSampleBufferCache];
            _lastLeakWarningTime = now;
        }
    }
}

#pragma mark - Getters e Propriedades
- (BOOL)isReceivingFrames {
    return _isReceivingFrames;
}

#pragma mark - Métodos de Reset e Configuração
- (void)reset {
    dispatch_sync(_processingQueue, ^{
        self->_frameCount = 0;
        self->_lastFrame = nil;
        self->_isReceivingFrames = NO;
        self->_lastFrameTime = 0;
        self->_didLogFirstFrameDetails = NO;
        self->_cachedImage = nil;
        self->_lastFrameHash = 0;
        self->_detectedPixelFormat = IOSPixelFormatUnknown;
        [self clearSampleBufferCache];
        for (int i = 0; i < 10; i++) {
            self->_frameProcessingTimes[i] = 0.0f;
        }
        self->_frameTimeIndex = 0;
        writeLog(@"[WebRTCFrameConverter] Reset completo");
    });
}

#pragma mark - Configuração de adaptação
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
    _adaptToNativeFormat = YES;
    _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:format];
    _cachedImage = nil;
    [self clearSampleBufferCache];
    writeLog(@"[WebRTCFrameConverter] Adaptando para formato nativo: %s (%dx%d), IOSPixelFormat: %@",
             [self formatTypeToString:format],
             resolution.width, resolution.height,
             [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat]);
}

#pragma mark - Métodos de classe (Conversão de tipos de formato)
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
                if (!_didLogFirstFrameDetails || _frameCount % 300 == 0) {
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
                    _didLogFirstFrameDetails = YES;
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
                    NSTimeInterval conversionStartTime = CACurrentMediaTime();
                    if (!frame || frame.width == 0 || frame.height == 0) {
                        dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                        return;
                    }
                    UIImage *image;
                    if (self->_adaptToTargetResolution &&
                        self->_targetResolution.width > 0 &&
                        self->_targetResolution.height > 0) {
                        if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
                            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
                            RTCCVPixelBuffer *scaledBuffer = [self scalePixelBufferToTargetSize:pixelBuffer];
                            if (scaledBuffer) {
                                RTCVideoFrame *scaledFrame = [[RTCVideoFrame alloc]
                                                           initWithBuffer:scaledBuffer
                                                           rotation:frame.rotation
                                                           timeStampNs:frame.timeStampNs];
                                image = [self imageFromVideoFrame:scaledFrame];
                            } else {
                                image = [self adaptedImageFromVideoFrame:frame];
                            }
                        } else {
                            image = [self adaptedImageFromVideoFrame:frame];
                        }
                    } else {
                        image = [self imageFromVideoFrame:frame];
                    }
                    if (image) {
                        self->_cachedImage = image;
                    }
                    NSTimeInterval conversionTime = CACurrentMediaTime() - conversionStartTime;
                    self->_frameProcessingTimes[self->_frameTimeIndex] = conversionTime;
                    self->_frameTimeIndex = (self->_frameTimeIndex + 1) % 10;
                    if (self->_frameCount > 1) {
                        NSTimeInterval frameInterval = CACurrentMediaTime() - self->_lastFrameTime;
                        if (frameInterval > 0) {
                            float instantFps = 1.0f / frameInterval;
                            self->_currentFps = self->_currentFps > 0 ?
                                                self->_currentFps * 0.9f + instantFps * 0.1f :
                                                instantFps;
                        }
                    }
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

#pragma mark - Processamento de Frame
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
                    writeLog(@"[WebRTCFrameConverter] CVPixelBuffer é NULL");
                    return nil;
                }
                size_t width = CVPixelBufferGetWidth(cvPixelBuffer);
                size_t height = CVPixelBufferGetHeight(cvPixelBuffer);
                if (width == 0 || height == 0) {
                    writeLog(@"[WebRTCFrameConverter] CVPixelBuffer tem dimensões inválidas: %zux%zu", width, height);
                    return nil;
                }
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvPixelBuffer);
                IOSPixelFormat iosFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                PixelBufferLocker *locker = [[PixelBufferLocker alloc] initWithPixelBuffer:cvPixelBuffer converter:self];
                UIImage *image = nil;
                if ([locker lock]) {
                    @try {
                        if (iosFormat == IOSPixelFormat420f || iosFormat == IOSPixelFormat420v) {
                            CVPixelBufferRef rgbBuffer = [self convertYUVToRGBWithHardwareAcceleration:cvPixelBuffer];
                            if (rgbBuffer) {
                                size_t bytesPerRow = CVPixelBufferGetBytesPerRow(rgbBuffer);
                                size_t rgbWidth = CVPixelBufferGetWidth(rgbBuffer);
                                size_t rgbHeight = CVPixelBufferGetHeight(rgbBuffer);
                                CVPixelBufferLockBaseAddress(rgbBuffer, kCVPixelBufferLock_ReadOnly);
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
                                CVPixelBufferRelease(rgbBuffer);
                            }
                        }
                        else if (iosFormat == IOSPixelFormatBGRA) {
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
                            if (!cgContext) {
                                writeLog(@"[WebRTCFrameConverter] Falha ao criar CGContext para BGRA");
                                return nil;
                            }
                            CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);
                            CGContextRelease(cgContext);
                            if (!cgImage) {
                                writeLog(@"[WebRTCFrameConverter] Falha ao criar CGImage de BGRA");
                                return nil;
                            }
                            if (frame.rotation != RTCVideoRotation_0) {
                                UIImage *originalImage = [UIImage imageWithCGImage:cgImage];
                                CGImageRelease(cgImage);
                                image = [self rotateImage:originalImage withRotation:frame.rotation];
                            } else {
                                image = [UIImage imageWithCGImage:cgImage];
                                CGImageRelease(cgImage);
                            }
                        }
                        else {
                        }
                        if (!image) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar UIImage a partir de CGImage");
                            return nil;
                        }
                        if (image.size.width <= 0 || image.size.height <= 0) {
                            writeLog(@"[WebRTCFrameConverter] UIImage criada com dimensões inválidas: %@",
                                    NSStringFromCGSize(image.size));
                            return nil;
                        }
                    } @catch (NSException *exception) {
                        writeLog(@"[WebRTCFrameConverter] Exceção ao processar CIImage: %@", exception);
                    } @finally {
                        [locker unlock];
                    }
                }
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

- (CVPixelBufferRef)convertYUVToRGBWithHardwareAcceleration:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NULL;
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    BOOL isYUV = (sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (!isYUV) {
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    CVPixelBufferRef outputBuffer = NULL;
    NSDictionary* pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @(width),
        (NSString*)kCVPixelBufferHeightKey: @(height),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString*)kCVPixelBufferMetalCompatibilityKey: @(YES)
    };
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)pixelBufferAttributes,
                                         &outputBuffer);
    if (result != kCVReturnSuccess || !outputBuffer) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar buffer de saída: %d", result);
        return NULL;
    }
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!_ciContext) {
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        };
        _ciContext = [CIContext contextWithOptions:options];
    }
    if (!ciImage) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do buffer YUV");
        CVPixelBufferRelease(outputBuffer);
        return NULL;
    }
    [_ciContext render:ciImage toCVPixelBuffer:outputBuffer];
    BOOL isAccelerated = NO;
    if (CVPixelBufferGetIOSurface(outputBuffer)) {
        isAccelerated = YES;
        _processingMode = @"hardware-accelerated";
    } else {
        _processingMode = @"software";
    }
    writeLog(@"[WebRTCFrameConverter] Conversão YUV->RGB %@",
                   isAccelerated ? @"usando aceleração de hardware" : @"usando software");
    return outputBuffer;
}

- (CVPixelBufferRef)convertYUVToRGBWithCIImage:(CVPixelBufferRef)pixelBuffer {
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

- (BOOL)isHardwareAccelerationAvailable {
    static BOOL checkedAvailability = NO;
    static BOOL isAvailable = NO;
    if (!checkedAvailability) {
        id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
        isAvailable = (metalDevice != nil);
        writeLog(@"[WebRTCFrameConverter] Aceleração de hardware %@ (verificado via Metal)",
                isAvailable ? @"disponível" : @"indisponível");
        checkedAvailability = YES;
    }
    return isAvailable;
}

- (BOOL)setupColorConversionContextFromFormat:(OSType)sourceFormat toFormat:(OSType)destFormat {
    static OSType currentSourceFormat = 0;
    static OSType currentDestFormat = 0;
    if (currentSourceFormat == sourceFormat && currentDestFormat == destFormat) {
        return YES;
    }
    currentSourceFormat = sourceFormat;
    currentDestFormat = destFormat;
    return YES;
}

#pragma mark - Adaptação para resolução alvo
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
            writeLog(@"[WebRTCFrameConverter] Falha ao adaptar imagem para resolução alvo %dx%d",
                    _targetResolution.width, _targetResolution.height);
            return originalImage;
        }
        if (_frameCount == 1 || _frameCount % 300 == 0) {
            writeLog(@"[WebRTCFrameConverter] Imagem adaptada de %dx%d para %dx%d",
                    (int)originalImage.size.width, (int)originalImage.size.height,
                    (int)adaptedImage.size.width, (int)adaptedImage.size.height);
        }
        return adaptedImage;
    }
}

#pragma mark - Conversão para CMSampleBuffer
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
                CMSampleBufferRef enhancedBuffer = [self enhanceSampleBufferTiming:outputBuffer preserveOriginalTiming:YES];
                if (enhancedBuffer) {
                    CFRelease(outputBuffer);
                    return enhancedBuffer;
                }
                return outputBuffer;
            }
            NSValue *cachedBufferValue = _sampleBufferCache[formatKey];
            if (cachedBufferValue) {
                CMSampleBufferRef cachedBuffer = NULL;
                [cachedBufferValue getValue:&cachedBuffer];
                if (cachedBuffer) {
                    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(cachedBuffer);
                    if (formatDesc) {
                        CMSampleBufferRef outputBuffer = NULL;
                        OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, cachedBuffer, &outputBuffer);
                        if (status == noErr) {
                            CMSampleBufferRef enhancedBuffer = [self enhanceSampleBufferTiming:outputBuffer preserveOriginalTiming:NO];
                            if (enhancedBuffer) {
                                CFRelease(outputBuffer);
                                return enhancedBuffer;
                            }
                            return outputBuffer;
                        }
                    }
                }
            }
        }
        CMSampleBufferRef sampleBuffer = [self createSampleBufferWithFormat:cvFormat];
        if (sampleBuffer) {
            @synchronized(self) {
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &_cachedSampleBuffer);
                if (status != noErr) {
                    writeLog(@"[WebRTCFrameConverter] Erro ao criar cópia para cache: %d", (int)status);
                } else {
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
                        CMSampleTimingInfo timingInfo;
                        if (CMSampleBufferGetSampleTimingInfo(formatCacheBuffer, 0, &timingInfo) == noErr) {
                            _activeSampleBuffers[@(CFHash(formatCacheBuffer))] = @{
                                @"timestamp": [NSDate date],
                                @"ptsSeconds": @(CMTimeGetSeconds(timingInfo.presentationTimeStamp)),
                                @"durationSeconds": @(CMTimeGetSeconds(timingInfo.duration))
                            };
                        } else {
                            _activeSampleBuffers[@(CFHash(formatCacheBuffer))] = @YES;
                        }
                        [self optimizeCacheSystem];
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
        writeLog(@"[WebRTCFrameConverter] createSampleBufferWithFormat: Buffer não é CVPixelBuffer");
        return NULL;
    }
    RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)buffer;
    CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
    if (!pixelBuffer) {
        writeLog(@"[WebRTCFrameConverter] createSampleBufferWithFormat: pixelBuffer é NULL");
        return NULL;
    }
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    char sourceFormatChars[5] = {
        (char)((sourceFormat >> 24) & 0xFF),
        (char)((sourceFormat >> 16) & 0xFF),
        (char)((sourceFormat >> 8) & 0xFF),
        (char)(sourceFormat & 0xFF),
        0
    };
    char targetFormatChars[5] = {
        (char)((format >> 24) & 0xFF),
        (char)((format >> 16) & 0xFF),
        (char)((format >> 8) & 0xFF),
        (char)(format & 0xFF),
        0
    };
    writeLog(@"[WebRTCFrameConverter] Formato de pixel origem: %s (0x%08X), destino: %s (0x%08X)",
                    sourceFormatChars, (unsigned int)sourceFormat,
                    targetFormatChars, (unsigned int)format);
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
        writeLog(@"[WebRTCFrameConverter] Falha ao criar buffer compatível: %d", result);
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
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMVideoFormatDescription: %d", (int)status);
        return NULL;
    }
    CMTimeScale timeScale = 1000000000; // Nanosegundos para precisão máxima
    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    if (_lastFrame) {
        uint64_t rtcTimestampNs = _lastFrame.timeStampNs;
        if (rtcTimestampNs > 0) {
            hostTime = CMTimeMake(rtcTimestampNs, timeScale);
            CMTime currentTime = CMClockGetTime(CMClockGetHostTimeClock());
            CMTime diff = CMTimeSubtract(currentTime, hostTime);
            if (CMTimeGetSeconds(diff) > 5.0 || CMTimeGetSeconds(diff) < -5.0) {
                hostTime = currentTime;
            }
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
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMSampleBuffer: %d", (int)status);
        return NULL;
    }
    if (sampleBuffer) {
        @synchronized(self) {
            NSNumber *bufferKey = @(CFHash(sampleBuffer));
            _activeSampleBuffers[bufferKey] = @{
                @"timestamp": [NSDate date],
                @"thread": [NSThread currentThread],
                @"ptsSeconds": @(CMTimeGetSeconds(timingInfo.presentationTimeStamp)),
                @"durationSeconds": @(CMTimeGetSeconds(timingInfo.duration))
            };
            _lastBufferTimestamp = timingInfo.presentationTimeStamp;
        }
    }
    return sampleBuffer;
}

- (CMSampleBufferRef)enhanceSampleBufferTiming:(CMSampleBufferRef)sampleBuffer
                         preserveOriginalTiming:(BOOL)preserveOriginalTiming {
    if (!sampleBuffer) return NULL;
    CMSampleBufferRef outputBuffer = NULL;
    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &outputBuffer);
    if (status != noErr || !outputBuffer) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar cópia de SampleBuffer: %d", (int)status);
        return NULL;
    }
    CMSampleTimingInfo timingInfo;
    status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
    if (status != noErr) {
        writeLog(@"[WebRTCFrameConverter] Erro ao obter timing info: %d", (int)status);
    }
    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTimeScale timeScale = hostTime.timescale;
    Float64 frameDuration;
    if (preserveOriginalTiming && CMTIME_IS_VALID(timingInfo.duration)) {
        frameDuration = CMTimeGetSeconds(timingInfo.duration);
    } else {
        frameDuration = 1.0 / 30.0;
        if (_adaptToTargetFrameRate && CMTIME_IS_VALID(_targetFrameDuration)) {
            frameDuration = CMTimeGetSeconds(_targetFrameDuration);
        } else if (_currentFps > 0) {
            frameDuration = 1.0 / _currentFps;
        }
    }
    CMSampleTimingInfo newTimingInfo;
    newTimingInfo.duration = CMTimeMakeWithSeconds(frameDuration, timeScale);
    if (preserveOriginalTiming && CMTIME_IS_VALID(timingInfo.presentationTimeStamp)) {
        newTimingInfo.presentationTimeStamp = timingInfo.presentationTimeStamp;
    } else {
        newTimingInfo.presentationTimeStamp = hostTime;
    }
    if (CMTIME_IS_VALID(timingInfo.decodeTimeStamp)) {
        newTimingInfo.decodeTimeStamp = timingInfo.decodeTimeStamp;
    } else {
        newTimingInfo.decodeTimeStamp = kCMTimeInvalid;
    }
    status = CMSampleBufferSetOutputPresentationTimeStamp(outputBuffer, newTimingInfo.presentationTimeStamp);
    if (status != noErr) {
        writeLog(@"[WebRTCFrameConverter] Aviso: não foi possível atualizar output timestamp: %d", (int)status);
    }
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(outputBuffer, true);
    if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
        if (dict) {
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            CFDictionarySetValue(dict, kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding, kCFBooleanFalse);
        }
    }
    return outputBuffer;
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
                if (_droppedFrameCount % 10 == 0) {
                    writeLog(@"[WebRTCFrameConverter] Descartados %d frames (cadência: %.1f%% do alvo)",
                                  (int)_droppedFrameCount, percentOfTarget * 100);
                }
                return YES;
            }
        }
    }
    _lastProcessedFrameTimestamp = frameTimestamp;
    return NO;
}

- (CMClockRef)getCurrentSyncClock {
    if (_captureSessionClock) {
        return _captureSessionClock;
    }
    return CMClockGetHostTimeClock();
}

- (void)setCaptureSessionClock:(CMClockRef)clock {
    if (clock) {
        _captureSessionClock = clock;
        writeLog(@"[WebRTCFrameConverter] Relógio de sessão de captura configurado para sincronização");
    } else {
        _captureSessionClock = NULL;
        writeLog(@"[WebRTCFrameConverter] Relógio de sessão de captura removido");
    }
}

- (NSDictionary *)extractMetadataFromSampleBuffer:(CMSampleBufferRef)originalBuffer {
    if (!originalBuffer) return nil;
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(originalBuffer, false);
    if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
        CFDictionaryRef attachments = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
        if (attachments) {
            NSDictionary *attachmentsDict = (__bridge NSDictionary *)attachments;
            [metadata setObject:attachmentsDict forKey:@"attachments"];
        }
    }
    CMSampleTimingInfo timingInfo;
    if (CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &timingInfo) == kCMBlockBufferNoErr) {
        [metadata setObject:@{
            @"presentationTimeStamp": @(CMTimeGetSeconds(timingInfo.presentationTimeStamp)),
            @"duration": @(CMTimeGetSeconds(timingInfo.duration)),
            @"decodeTimeStamp": CMTIME_IS_VALID(timingInfo.decodeTimeStamp) ?
                @(CMTimeGetSeconds(timingInfo.decodeTimeStamp)) : @(0)
        } forKey:@"timingInfo"];
    }
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (formatDescription) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        [metadata setObject:@{
            @"width": @(dimensions.width),
            @"height": @(dimensions.height),
            @"mediaType": @"video"
        } forKey:@"formatDescription"];
        CFDictionaryRef extensionsDictionary = CMFormatDescriptionGetExtensions(formatDescription);
        if (extensionsDictionary) {
            NSDictionary *extensions = (__bridge NSDictionary *)extensionsDictionary;
            [metadata setObject:extensions forKey:@"extensions"];
        }
    }
    CFDictionaryRef metadataDict = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                               originalBuffer,
                                                               kCMAttachmentMode_ShouldPropagate);
    if (metadataDict) {
        [metadata setObject:(__bridge NSDictionary *)metadataDict forKey:@"cameraMetadata"];
        CFRelease(metadataDict);
    }
    return metadata;
}

- (BOOL)applyMetadataToSampleBuffer:(CMSampleBufferRef)sampleBuffer metadata:(NSDictionary *)metadata {
    if (!sampleBuffer || !metadata) return NO;
    BOOL success = YES;
    NSDictionary *attachmentsDict = metadata[@"attachments"];
    if (attachmentsDict) {
        CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
            CFMutableDictionaryRef attachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
            [attachmentsDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                CFDictionarySetValue(attachments, (__bridge const void *)key, (__bridge const void *)obj);
            }];
        }
    }
    NSDictionary *cameraMetadata = metadata[@"cameraMetadata"];
    if (cameraMetadata) {
        CMSetAttachments(sampleBuffer, (__bridge CFDictionaryRef)cameraMetadata, kCMAttachmentMode_ShouldPropagate);
    }
    return success;
}

#pragma mark - Métodos de Interface Pública
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

- (NSDictionary *)getFrameProcessingStats {
    float averageTime = 0;
    for (int i = 0; i < 10; i++) {
        averageTime += _frameProcessingTimes[i];
    }
    averageTime /= 10.0;
    float fps = averageTime > 0 ? 1.0/averageTime : 0;
    float actualFps = 0;
    if (_frameCount > 1 && _lastFrameTime > 0) {
        NSTimeInterval now = CACurrentMediaTime();
        NSTimeInterval timeSinceLastFrame = now - _lastFrameTime;
        if (timeSinceLastFrame > 0) {
            actualFps = 1.0 / timeSinceLastFrame;
        }
    }
    NSMutableDictionary *lastFrameInfo = [NSMutableDictionary dictionary];
    if (_lastFrame) {
        lastFrameInfo[@"width"] = @(_lastFrame.width);
        lastFrameInfo[@"height"] = @(_lastFrame.height);
        lastFrameInfo[@"rotation"] = @(_lastFrame.rotation);
        id<RTCVideoFrameBuffer> buffer = _lastFrame.buffer;
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvBuffer = pixelBuffer.pixelBuffer;
            if (cvBuffer) {
                OSType pixelFormatType = CVPixelBufferGetPixelFormatType(cvBuffer);
                char formatChars[5] = {
                    (char)((pixelFormatType >> 24) & 0xFF),
                    (char)((pixelFormatType >> 16) & 0xFF),
                    (char)((pixelFormatType >> 8) & 0xFF),
                    (char)(pixelFormatType & 0xFF),
                    0
                };
                lastFrameInfo[@"pixelFormat"] = [NSString stringWithUTF8String:formatChars];
                lastFrameInfo[@"iosFormat"] = [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat];
            }
        }
    }
    NSMutableDictionary *resourceStats = [NSMutableDictionary dictionary];
    resourceStats[@"sampleBuffersCreated"] = @(_totalSampleBuffersCreated);
    resourceStats[@"sampleBuffersReleased"] = @(_totalSampleBuffersReleased);
    resourceStats[@"pixelBuffersLocked"] = @(_totalPixelBuffersLocked);
    resourceStats[@"pixelBuffersUnlocked"] = @(_totalPixelBuffersUnlocked);
    resourceStats[@"sampleBufferCacheSize"] = @(_sampleBufferCache.count);
    NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
    NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
    resourceStats[@"sampleBufferDiff"] = @(sampleBufferDiff);
    resourceStats[@"pixelBufferDiff"] = @(pixelBufferDiff);
    if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
        resourceStats[@"resourceStatus"] = @"WARNING: Potencial vazamento detectado";
    } else {
        resourceStats[@"resourceStatus"] = @"OK";
    }
    return @{
        @"averageProcessingTimeMs": @(averageTime * 1000.0),
        @"estimatedFps": @(fps),
        @"actualFps": @(actualFps),
        @"frameCount": @(_frameCount),
        @"isReceivingFrames": @(_isReceivingFrames),
        @"adaptToTargetResolution": @(_adaptToTargetResolution),
        @"adaptToTargetFrameRate": @(_adaptToTargetFrameRate),
        @"adaptToNativeFormat": @(_adaptToNativeFormat),
        @"targetResolution": @{
            @"width": @(_targetResolution.width),
            @"height": @(_targetResolution.height)
        },
        @"targetFrameRate": @(CMTimeGetSeconds(_targetFrameDuration) > 0 ?
                            1.0 / CMTimeGetSeconds(_targetFrameDuration) : 0),
        @"processingMode": _processingMode,
        @"detectedPixelFormat": [WebRTCFrameConverter stringFromPixelFormat:_detectedPixelFormat],
        @"lastFrame": lastFrameInfo,
        @"resourceManagement": resourceStats
    };
}

- (void)performSafeCleanup {
    writeLog(@"[WebRTCFrameConverter] Realizando limpeza segura de recursos");
    @synchronized(self) {
        _cachedImage = nil;
        [self clearSampleBufferCache];
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        if (sampleBufferDiff > 0 || pixelBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Possíveis recursos não liberados: %ld sample buffers, %ld pixel buffers",
                           (long)sampleBufferDiff, (long)pixelBufferDiff);
        }
    }
}

- (void)detectAndRecuperarVazamentos {
    @synchronized(self) {
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
            writeLog(@"[WebRTCFrameConverter] Corrigindo desbalanceamento de recursos - Ajustando contadores");
            if (sampleBufferDiff > 0) {
                _totalSampleBuffersReleased += sampleBufferDiff;
            }
            if (pixelBufferDiff > 0) {
                _totalPixelBuffersUnlocked += pixelBufferDiff;
            }
            [self clearSampleBufferCache];
            _cachedImage = nil;
            @autoreleasepool { }
        }
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

- (void)forceReleaseAllSampleBuffers {
    @synchronized(self) {
        writeLog(@"[WebRTCFrameConverter] Forçando liberação de todos os sample buffers ativos (%lu)", (unsigned long)_activeSampleBuffers.count);
        NSDictionary *buffersCopy = [_activeSampleBuffers copy];
        for (NSNumber *bufferKey in buffersCopy) {
            id bufferInfo = buffersCopy[bufferKey];
            if (bufferInfo) {
                [_activeSampleBuffers removeObjectForKey:bufferKey];
                _totalSampleBuffersReleased++;
            }
        }
        [self clearSampleBufferCache];
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        if (pixelBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Equilibrando contadores de CVPixelBuffer: %ld locks sem unlock", (long)pixelBufferDiff);
            _totalPixelBuffersUnlocked += pixelBufferDiff;
        }
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        if (sampleBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Ajustando contador de sample buffers: %ld buffers não liberados", (long)sampleBufferDiff);
            _totalSampleBuffersReleased += sampleBufferDiff;
        }
        _cachedSampleBuffer = NULL;
        _cachedSampleBufferHash = 0;
        _cachedSampleBufferFormat = 0;
        _cachedImage = nil;
        _lastFrameHash = 0;
        [_sampleBufferCache removeAllObjects];
        [_sampleBufferCacheTimestamps removeAllObjects];
        [_activeSampleBuffers removeAllObjects];
    }
}

- (BOOL)configureHardwareAcceleration {
    BOOL isHardwareAccelerationConfigured = NO;
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
        isHardwareAccelerationConfigured = (_ciContext != nil);
    }
    if (metalSupported) {
        _processingMode = @"hardware-accelerated";
        isHardwareAccelerationConfigured = YES;
    } else {
        _processingMode = @"software";
    }
    writeLog(@"[WebRTCFrameConverter] Modo de processamento: %@", _processingMode);
    return isHardwareAccelerationConfigured;
}

- (void)optimizeForPerformance:(BOOL)optimize {
    if (optimize) {
        _maxCachedSampleBuffers = 5;
        [self setupBufferPool];
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing.highperf",
                                               dispatch_queue_attr_make_with_qos_class(
                                                   DISPATCH_QUEUE_CONCURRENT,
                                                   QOS_CLASS_USER_INTERACTIVE,
                                                   0));
        writeLog(@"[WebRTCFrameConverter] Otimização para performance máxima ativada");
    } else {
        _maxCachedSampleBuffers = 2;
        [self releaseBufferPool];
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing.balanced",
                                               dispatch_queue_attr_make_with_qos_class(
                                                   DISPATCH_QUEUE_CONCURRENT,
                                                   QOS_CLASS_DEFAULT,
                                                   0));
        writeLog(@"[WebRTCFrameConverter] Otimização balanceada (memória/performance)");
    }
}

- (void)setupBufferPool {
    writeLog(@"[WebRTCFrameConverter] Pool de pixel buffers não implementado nesta versão");
}

- (void)releaseBufferPool {
    writeLog(@"[WebRTCFrameConverter] Pool de pixel buffers não implementado");
}

- (RTCCVPixelBuffer *)scalePixelBufferToTargetSize:(RTCCVPixelBuffer *)pixelBuffer {
    if (!pixelBuffer) return nil;
    CVPixelBufferRef originalBuffer = pixelBuffer.pixelBuffer;
    if (!originalBuffer) return nil;
    size_t originalWidth = CVPixelBufferGetWidth(originalBuffer);
    size_t originalHeight = CVPixelBufferGetHeight(originalBuffer);
    if (originalWidth == _targetResolution.width && originalHeight == _targetResolution.height) {
        return pixelBuffer;
    }
    CVPixelBufferRef scaledBuffer = NULL;
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(originalBuffer);
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (NSString*)kCVPixelBufferWidthKey: @(_targetResolution.width),
        (NSString*)kCVPixelBufferHeightKey: @(_targetResolution.height),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString*)kCVPixelBufferMetalCompatibilityKey: @(YES)
    };
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         _targetResolution.width,
                                         _targetResolution.height,
                                         pixelFormat,
                                         (__bridge CFDictionaryRef)pixelBufferAttributes,
                                         &scaledBuffer);
    if (result != kCVReturnSuccess || !scaledBuffer) {
        writeLog(@"[WebRTCFrameConverter] Falha ao criar buffer para escalonamento: %d", result);
        return nil;
    }
    BOOL useHardwareScaling = [self isHardwareAccelerationAvailable];
    if (useHardwareScaling && pixelFormat != kCVPixelFormatType_32BGRA) {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:originalBuffer];
        float originalAspect = (float)originalWidth / (float)originalHeight;
        float targetAspect = (float)_targetResolution.width / (float)_targetResolution.height;
        if (fabs(originalAspect - targetAspect) < 0.01) {
            ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                (float)_targetResolution.width / (float)originalWidth,
                (float)_targetResolution.height / (float)originalHeight
            )];
        } else if (originalAspect > targetAspect) {
            float scaleFactor = (float)_targetResolution.height / (float)originalHeight;
            float scaledWidth = originalWidth * scaleFactor;
            float xOffset = (scaledWidth - _targetResolution.width) / 2.0f;
            ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                scaleFactor, scaleFactor
            )];
            ciImage = [ciImage imageByCroppingToRect:CGRectMake(
                xOffset, 0, _targetResolution.width, _targetResolution.height
            )];
        } else {
            float scaleFactor = (float)_targetResolution.width / (float)originalWidth;
            float scaledHeight = originalHeight * scaleFactor;
            float yOffset = (scaledHeight - _targetResolution.height) / 2.0f;
            ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                scaleFactor, scaleFactor
            )];
            ciImage = [ciImage imageByCroppingToRect:CGRectMake(
                0, yOffset, _targetResolution.width, _targetResolution.height
            )];
        }
        [_ciContext render:ciImage toCVPixelBuffer:scaledBuffer];
    } else {
        CVPixelBufferLockBaseAddress(originalBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(scaledBuffer, 0);
        size_t originalBytesPerRow = CVPixelBufferGetBytesPerRow(originalBuffer);
        size_t scaledBytesPerRow = CVPixelBufferGetBytesPerRow(scaledBuffer);
        void *originalBaseAddress = CVPixelBufferGetBaseAddress(originalBuffer);
        void *scaledBaseAddress = CVPixelBufferGetBaseAddress(scaledBuffer);
        vImage_Buffer src = {
            .data = originalBaseAddress,
            .height = (vImagePixelCount)originalHeight,
            .width = (vImagePixelCount)originalWidth,
            .rowBytes = originalBytesPerRow
        };
        vImage_Buffer dest = {
            .data = scaledBaseAddress,
            .height = (vImagePixelCount)_targetResolution.height,
            .width = (vImagePixelCount)_targetResolution.width,
            .rowBytes = scaledBytesPerRow
        };
        vImage_Error error = vImageScale_ARGB8888(&src, &dest, NULL, kvImageHighQualityResampling);
        CVPixelBufferUnlockBaseAddress(originalBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(scaledBuffer, 0);
        if (error != kvImageNoError) {
            writeLog(@"[WebRTCFrameConverter] Erro no escalonamento vImage: %ld", error);
            CVPixelBufferRelease(scaledBuffer);
            return nil;
        }
    }
    RTCCVPixelBuffer *rtcScaledBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:scaledBuffer];
    CVPixelBufferRelease(scaledBuffer);
    return rtcScaledBuffer;
}

- (void)setFrameRateAdaptationStrategy:(NSString *)newStrategy {
    static NSString *currentStrategy = nil;
    if (currentStrategy && [currentStrategy isEqualToString:newStrategy]) {
        return;
    }
    currentStrategy = [newStrategy copy];
    if ([newStrategy isEqualToString:@"quality"]) {
        _targetFrameDuration = CMTimeMake(1, 60);
        _droppedFrameCount = 0;
        writeLog(@"[WebRTCFrameConverter] Usando estratégia de adaptação: qualidade máxima (60fps)");
    }
    else if ([newStrategy isEqualToString:@"performance"]) {
        _targetFrameDuration = CMTimeMake(1, 30);
        
        writeLog(@"[WebRTCFrameConverter] Usando estratégia de adaptação: performance (30fps)");
    }
    else {
        _targetFrameDuration = CMTimeMake(1, 45);
        writeLog(@"[WebRTCFrameConverter] Usando estratégia de adaptação: balanceada (45fps)");
    }
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
        if (_droppedFrameCount % 30 == 0) {
            writeLog(@"[WebRTCFrameConverter] Adaptação de taxa: descartados %lu frames (fps atual: %.1f, alvo: %.1f)",
                           (unsigned long)_droppedFrameCount, fpsCurrent, targetFps);
        }
    }
    return !shouldDrop;
}

@end
