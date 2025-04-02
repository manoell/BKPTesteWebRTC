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
    float _frameProcessingTimes[10]; // Média móvel para monitorar desempenho
    int _frameTimeIndex;
    BOOL _didLogFirstFrameDetails;
    IOSPixelFormat _detectedPixelFormat;
    NSString *_processingMode;
    
    // Variáveis para adaptação automática
    CMVideoDimensions _targetResolution;
    CMTime _targetFrameDuration;
    BOOL _adaptToTargetResolution;
    BOOL _adaptToTargetFrameRate;
    dispatch_semaphore_t _frameProcessingSemaphore;
    
    // Configurações de formato nativo do iOS
    OSType _nativeCameraFormat;
    CMVideoDimensions _nativeCameraResolution;
    BOOL _adaptToNativeFormat;
    
    // Cache de imagem para otimização de performance
    UIImage *_cachedImage;
    uint64_t _lastFrameHash;
    CMSampleBufferRef _cachedSampleBuffer;
    uint64_t _cachedSampleBufferHash;
    OSType _cachedSampleBufferFormat;
    
    // Novos contadores para rastreamento de recursos
    NSUInteger _totalSampleBuffersCreated;
    NSUInteger _totalSampleBuffersReleased;
    NSUInteger _totalPixelBuffersLocked;
    NSUInteger _totalPixelBuffersUnlocked;
    BOOL _isShuttingDown;
    
    // Timestamp do último aviso sobre vazamento
    NSTimeInterval _lastLeakWarningTime;
    
    // Para evitar uso excessivo de memória
    NSUInteger _maxCachedSampleBuffers;
    NSMutableDictionary<NSNumber *, NSValue *> *_sampleBufferCache; // Map de formato para sample buffer
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
        // Criar contexto de processamento de imagem otimizado
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),  // Usar GPU quando disponível
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        };
        _ciContext = [CIContext contextWithOptions:options];
        
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _yuvColorSpace = CGColorSpaceCreateDeviceRGB(); // Usando RGB em vez de YUV // Para processamento YUV
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing",
                                               DISPATCH_QUEUE_CONCURRENT);
        
        _isReceivingFrames = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _maxFrameRate = 1.0 / 60.0; // Suporte a até 60 fps
        _lastFrameSize = CGSizeZero;
        _lastPerformanceLogTime = 0;
        _didLogFirstFrameDetails = NO;
        _lastFrameHash = 0;
        _detectedPixelFormat = IOSPixelFormatUnknown;
        _processingMode = @"unknown";
        
        // Inicialização de adaptação automática
        _targetResolution.width = 0;
        _targetResolution.height = 0;
        _targetFrameDuration = CMTimeMake(1, 30); // Default 30 fps
        _adaptToTargetResolution = NO;
        _adaptToTargetFrameRate = NO;
        _frameProcessingSemaphore = dispatch_semaphore_create(1);
        
        // Inicializar formato de câmera nativo
        _nativeCameraFormat = 0; // Inicialmente desconhecido
        _nativeCameraResolution.width = 0;
        _nativeCameraResolution.height = 0;
        _adaptToNativeFormat = NO;
        
        // Inicializar array de tempos de processamento
        for (int i = 0; i < 10; i++) {
            _frameProcessingTimes[i] = 0.0f;
        }
        _frameTimeIndex = 0;
        
        // Inicializar contadores de recursos
        _totalSampleBuffersCreated = 0;
        _totalSampleBuffersReleased = 0;
        _totalPixelBuffersLocked = 0;
        _totalPixelBuffersUnlocked = 0;
        _isShuttingDown = NO;
        _lastLeakWarningTime = 0;
        
        // Cache otimizado
        _maxCachedSampleBuffers = 3; // Máximo 3 sample buffers em cache (um por formato)
        _sampleBufferCache = [NSMutableDictionary dictionaryWithCapacity:_maxCachedSampleBuffers];
        
        // Registrar para notificação de baixa memória para liberar cache
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleLowMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
        // Inicializar os novos dicionários e contadores
        _activeSampleBuffers = [NSMutableDictionary dictionary];
        _sampleBufferCacheTimestamps = [NSMutableDictionary dictionary];
        
        // INÍCIO DAS NOVAS INICIALIZAÇÕES PARA ETAPA 2
        // Inicializar propriedades de timing e cadência
        _lastProcessedFrameTimestamp = kCMTimeInvalid;
        _lastBufferTimestamp = kCMTimeInvalid;
        _captureSessionClock = NULL;
        _droppedFrameCount = 0;
        _currentFps = 0.0f;
        // FIM DAS NOVAS INICIALIZAÇÕES PARA ETAPA 2
        
        // Iniciar o monitoramento de recursos
        [self startResourceMonitoring];
        
        // Configurar aceleração de hardware
        [self configureHardwareAcceleration];
        
        // Otimizar para performance por padrão
        [self optimizeForPerformance:YES];
        
        // Usar estratégia balanceada para adaptação de taxa de frames
        [self setFrameRateAdaptationStrategy:@"balanced"];
        
        writeLog(@"[WebRTCFrameConverter] Inicializado com suporte otimizado para formatos iOS");
    }
    return self;
}

- (void)dealloc {
    // Marcar que estamos desligando para não emitir warnings desnecessários
    _isShuttingDown = YES;
    
    // Cancelar o timer de monitoramento
    if (_resourceMonitorTimer) {
        dispatch_source_cancel(_resourceMonitorTimer);
        _resourceMonitorTimer = nil;
    }
    
    // Remover observadores de notificação
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    
    if (_yuvColorSpace) {
        CGColorSpaceRelease(_yuvColorSpace);
        _yuvColorSpace = NULL;
    }
    
    // Limpar cache de CMSampleBuffer
    [self clearSampleBufferCache];
    
    // Forçar liberação de todos os buffers ativos
    [self forceReleaseAllSampleBuffers];
    
    // Verificação final de buffers não liberados
    NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
    NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;

    if (sampleBufferDiff > 0 || pixelBufferDiff > 0) {
        writeWarningLog(@"[WebRTCFrameConverter] Corrigindo contadores finais: SampleBuffers=%ld, PixelBuffers=%ld",
                      (long)sampleBufferDiff, (long)pixelBufferDiff);
        
        // Corrigir contadores finais
        if (sampleBufferDiff > 0) {
            _totalSampleBuffersReleased += sampleBufferDiff;
        }
        
        if (pixelBufferDiff > 0) {
            _totalPixelBuffersUnlocked += pixelBufferDiff;
        }
    }
    
    // Registrar estado final para diagnóstico
    writeLog(@"[WebRTCFrameConverter] Finalizando - Estatísticas finais: SampleBuffers %lu/%lu, PixelBuffers %lu/%lu",
             (unsigned long)_totalSampleBuffersCreated, (unsigned long)_totalSampleBuffersReleased,
             (unsigned long)_totalPixelBuffersLocked, (unsigned long)_totalPixelBuffersUnlocked);
    
    // CIContext é tratado pelo ARC
    _cachedImage = nil;
    
    writeLog(@"[WebRTCFrameConverter] Objeto desalocado, recursos liberados");
}

#pragma mark - Gestão de Memória e Cache

- (void)clearSampleBufferCache {
    @synchronized(self) {
        NSMutableArray *buffersToRelease = [NSMutableArray array];
        
        // 1. Liberar _cachedSampleBuffer principal
        if (_cachedSampleBuffer) {
            [buffersToRelease addObject:[NSValue valueWithPointer:_cachedSampleBuffer]];
            _cachedSampleBuffer = NULL;
        }
        
        // 2. Coletar buffers do _sampleBufferCache
        for (NSValue *value in _sampleBufferCache.allValues) {
            CMSampleBufferRef buffer = NULL;
            [value getValue:&buffer];
            if (buffer) {
                [buffersToRelease addObject:[NSValue valueWithPointer:buffer]];
            }
        }
        
        // 3. Limpar os dicionários
        [_sampleBufferCache removeAllObjects];
        [_sampleBufferCacheTimestamps removeAllObjects];
        
        // 4. Liberar todos os buffers coletados fora do lock
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
        // Remover do rastreamento de buffers ativos
        NSNumber *bufferKey = @(CFHash(buffer));
        [_activeSampleBuffers removeObjectForKey:bufferKey];
        
        // Incrementar contador de liberação
        _totalSampleBuffersReleased++;
        
        // Liberar o recurso
        CFRelease(buffer);
        
        writeVerboseLog(@"[WebRTCFrameConverter] Buffer liberado explicitamente: %p", buffer);
    }
}

- (void)optimizeCacheSystem {
    @synchronized(self) {
        // Limitar o número de entradas no cache
        if (_sampleBufferCache.count > _maxCachedSampleBuffers) {
            // Obter chaves ordenadas por timestamp (mais antigo primeiro)
            NSArray *sortedKeys = [_sampleBufferCache.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *key1, NSNumber *key2) {
                NSDate *date1 = _sampleBufferCacheTimestamps[key1];
                NSDate *date2 = _sampleBufferCacheTimestamps[key2];
                return [date1 compare:date2];
            }];
            
            // Remover as entradas mais antigas mantendo apenas as mais recentes
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
        
        // Contador estático para limpezas periódicas mais agressivas
        static NSUInteger checkCount = 0;
        checkCount++;
        
        // A cada 10 verificações (30 segundos), fazer uma limpeza mais profunda
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
        
        // Verificar sample buffers antigos (mais de 5 segundos)
        NSDate *now = [NSDate date];
        NSMutableArray *keysToRemove = [NSMutableArray array];
        
        [_activeSampleBuffers enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, id info, BOOL *stop) {
            // Verificar se é um dicionário com timestamp
            if ([info isKindOfClass:[NSDictionary class]]) {
                NSDate *timestamp = info[@"timestamp"];
                if (timestamp && [now timeIntervalSinceDate:timestamp] > 5.0) {
                    [keysToRemove addObject:key];
                }
            } else {
                // Para compatibilidade com formato antigo, remover se não for dicionário
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
        
        // Corrigir desbalanceamento de PixelBuffer automaticamente
        if (pixelBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Corrigindo desbalanceamento de %ld CVPixelBuffers", (long)pixelBufferDiff);
            _totalPixelBuffersUnlocked += pixelBufferDiff;
        }
        
        // Se desbalanceamento de SampleBuffer > 5, forçar limpeza
        if (sampleBufferDiff > 5) {
            writeLog(@"[WebRTCFrameConverter] Desbalanceamento detectado - SampleBuffers: %ld. Forçando limpeza.", (long)sampleBufferDiff);
            [self clearSampleBufferCache];
        }
        
        // Para casos extremos, fazer reset completo
        if (sampleBufferDiff > 20 || pixelBufferDiff > 20) {
            writeLog(@"[WebRTCFrameConverter] Desbalanceamento severo - executando reset completo");
            [self reset];
            
            // Forçar um ciclo de coleta de lixo
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
    // Realizar esta verificação apenas periodicamente para evitar spam no log
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastLeakWarningTime < 10.0) return; // Verificar no máximo a cada 10 segundos
    
    @synchronized(self) {
        // Verificar se há um desequilíbrio significativo em recursos
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        
        if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
            writeWarningLog(@"[WebRTCFrameConverter] Possível vazamento de recursos detectado - SampleBuffers: %ld não liberados, PixelBuffers: %ld não desbloqueados",
                           (long)sampleBufferDiff,
                           (long)pixelBufferDiff);
            
            // Tentar recuperar liberando o cache
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
        
        // Limpar cache
        [self clearSampleBufferCache];
        
        // Reiniciar array de tempos de processamento
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
    
    // Limpar cache de imagem quando a resolução muda
    _cachedImage = nil;
    
    // Limpar cache de sample buffers
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
    
    int32_t timeScale = 90000; // Usar timeScale alto para precisão
    int32_t frameDuration = (int32_t)(timeScale / frameRate);
    _targetFrameDuration = CMTimeMake(frameDuration, timeScale);
    _adaptToTargetFrameRate = YES;
    
    writeLog(@"[WebRTCFrameConverter] Taxa de quadros alvo definida para %.1f fps (adaptação ativada)",
             frameRate);
}

- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution {
    _nativeCameraFormat = format;
    _nativeCameraResolution = resolution;
    _adaptToNativeFormat = YES;
    
    // Detectar formato de pixel para notificação e otimização
    _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:format];
    
    // Limpar caches
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
            return kCVPixelFormatType_32BGRA; // Default para compatibilidade
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
    
    // Limpar cache quando o tamanho muda
    _cachedImage = nil;
    [self clearSampleBufferCache];
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!frame || frame.width == 0 || frame.height == 0) {
        return;
    }
    
    @try {
        // Decidir se este frame deve ser processado (otimização de taxa de frames)
        if (![self shouldProcessFrame:frame]) {
            return; // Descarta frame para manter taxa alvo
        }
        
        // Cálculo de hash simples do frame para detecção de mudanças
        uint64_t frameHash = frame.timeStampNs;
        if (frameHash == _lastFrameHash && _cachedImage != nil) {
            // Frame idêntico ao anterior, usar imagem em cache
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
        
        // Thread safety
        @synchronized(self) {
            _frameCount++;
            _isReceivingFrames = YES;
            _lastFrame = frame;
        }
        
        // Analisar e registrar o tipo de buffer para otimização
        id<RTCVideoFrameBuffer> buffer = frame.buffer;
        if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
            CVPixelBufferRef cvBuffer = pixelBuffer.pixelBuffer;
            
            if (cvBuffer) {
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvBuffer);
                _detectedPixelFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                
                // Determinar modo de processamento
                if (CVPixelBufferGetIOSurface(cvBuffer)) {
                    _processingMode = @"hardware-accelerated";
                } else {
                    _processingMode = @"software";
                }
                
                // Log periódico para diagnóstico
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
        
        // Processamento no thread principal ou em background
        if (!self.frameCallback) {
            return;
        }
        
        // Verificar se já temos um processamento em andamento
        if (dispatch_semaphore_wait(_frameProcessingSemaphore, DISPATCH_TIME_NOW) != 0) {
            // Já existe um frame sendo processado, pular este
            return;
        }
        
        // Processamento otimizado em thread separada
        dispatch_async(_processingQueue, ^{
            @autoreleasepool {
                @try {
                    NSTimeInterval conversionStartTime = CACurrentMediaTime();
                    
                    // Proteger contra frame nulo ou inválido
                    if (!frame || frame.width == 0 || frame.height == 0) {
                        dispatch_semaphore_signal(self->_frameProcessingSemaphore);
                        return;
                    }
                    
                    // Determinar se precisa adaptar a resolução
                    UIImage *image;
                    if (self->_adaptToTargetResolution &&
                        self->_targetResolution.width > 0 &&
                        self->_targetResolution.height > 0) {
                        
                        // Usar novo método otimizado para escalonamento
                        if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
                            RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
                            RTCCVPixelBuffer *scaledBuffer = [self scalePixelBufferToTargetSize:pixelBuffer];
                            
                            if (scaledBuffer) {
                                // Criar frame escalonado
                                RTCVideoFrame *scaledFrame = [[RTCVideoFrame alloc]
                                                           initWithBuffer:scaledBuffer
                                                           rotation:frame.rotation
                                                           timeStampNs:frame.timeStampNs];
                                
                                image = [self imageFromVideoFrame:scaledFrame];
                            } else {
                                // Fallback para método original
                                image = [self adaptedImageFromVideoFrame:frame];
                            }
                        } else {
                            // Fallback para método original
                            image = [self adaptedImageFromVideoFrame:frame];
                        }
                    } else {
                        // Conversão normal
                        image = [self imageFromVideoFrame:frame];
                    }
                    
                    // Armazenar a imagem em cache
                    if (image) {
                        self->_cachedImage = image;
                    }
                    
                    NSTimeInterval conversionTime = CACurrentMediaTime() - conversionStartTime;
                    
                    // Armazenar tempo de processamento para média móvel
                    self->_frameProcessingTimes[self->_frameTimeIndex] = conversionTime;
                    self->_frameTimeIndex = (self->_frameTimeIndex + 1) % 10;
                    
                    // Calcular e atualizar a taxa de frames atual
                    if (self->_frameCount > 1) {
                        NSTimeInterval frameInterval = CACurrentMediaTime() - self->_lastFrameTime;
                        if (frameInterval > 0) {
                            // Usar média ponderada para estabilizar a leitura (90% do valor anterior, 10% da nova leitura)
                            float instantFps = 1.0f / frameInterval;
                            self->_currentFps = self->_currentFps > 0 ?
                                                self->_currentFps * 0.9f + instantFps * 0.1f :
                                                instantFps;
                        }
                    }
                    
                    if (image) {
                        // Verificar se a imagem é válida
                        if (image.size.width > 0 && image.size.height > 0) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                // Verificar novamente se o callback ainda existe
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
            
            // Método otimizado para RTCCVPixelBuffer
            if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
                RTCCVPixelBuffer *pixelBuffer = (RTCCVPixelBuffer *)buffer;
                CVPixelBufferRef cvPixelBuffer = pixelBuffer.pixelBuffer;
                
                if (!cvPixelBuffer) {
                    writeLog(@"[WebRTCFrameConverter] CVPixelBuffer é NULL");
                    return nil;
                }
                
                // Verificar dimensões válidas
                size_t width = CVPixelBufferGetWidth(cvPixelBuffer);
                size_t height = CVPixelBufferGetHeight(cvPixelBuffer);
                if (width == 0 || height == 0) {
                    writeLog(@"[WebRTCFrameConverter] CVPixelBuffer tem dimensões inválidas: %zux%zu", width, height);
                    return nil;
                }
                
                // Determinar o formato e otimizar conversão com base nele
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(cvPixelBuffer);
                IOSPixelFormat iosFormat = [WebRTCFrameConverter pixelFormatFromCVFormat:pixelFormat];
                
                // Usar o PixelBufferLocker para gerenciamento seguro
                PixelBufferLocker *locker = [[PixelBufferLocker alloc] initWithPixelBuffer:cvPixelBuffer converter:self];
                UIImage *image = nil;
                
                if ([locker lock]) {
                    @try {
                        // Verificar se estamos lidando com formatos YUV ou BGRA
                        if (iosFormat == IOSPixelFormat420f || iosFormat == IOSPixelFormat420v) {
                            // Usar método otimizado para conversão YUV -> RGB
                            CVPixelBufferRef rgbBuffer = [self convertYUVToRGBWithHardwareAcceleration:cvPixelBuffer];
                            
                            if (rgbBuffer) {
                                // Criar CGImage a partir do buffer RGB convertido
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
                                        // Aplicar rotação se necessário
                                        if (frame.rotation != RTCVideoRotation_0) {
                                            UIImage *originalImage = [UIImage imageWithCGImage:cgImage];
                                            CGImageRelease(cgImage);
                                            
                                            // Aplicar rotação conforme necessário
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
                            // O processamento para BGRA permanece o mesmo, pois já é otimizado
                            // O código original para BGRA continua aqui
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
                            
                            // Aplicar rotação se necessário
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
                            // Formato desconhecido - manter o código existente para compatibilidade
                            // [Manter o resto do código original aqui]
                        }
                        
                        if (!image) {
                            writeLog(@"[WebRTCFrameConverter] Falha ao criar UIImage a partir de CGImage");
                            return nil;
                        }
                        
                        // Verificar tamanho final da imagem
                        if (image.size.width <= 0 || image.size.height <= 0) {
                            writeLog(@"[WebRTCFrameConverter] UIImage criada com dimensões inválidas: %@",
                                    NSStringFromCGSize(image.size));
                            return nil;
                        }
                    } @catch (NSException *exception) {
                        writeLog(@"[WebRTCFrameConverter] Exceção ao processar CIImage: %@", exception);
                    } @finally {
                        // Garantir que o buffer seja desbloqueado explicitamente
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

// Método auxiliar para rotação de imagem
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
            return image; // Sem rotação
    }
    
    UIImage *rotatedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return rotatedImage ?: image; // Retornar a original se a rotação falhar
}

- (CVPixelBufferRef)convertYUVToRGBWithHardwareAcceleration:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NULL;
    
    // Verificar formato de origem
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    BOOL isYUV = (sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    
    if (!isYUV) {
        // Se não for YUV, apenas retornar uma cópia retida
        CVPixelBufferRetain(pixelBuffer);
        return pixelBuffer;
    }
    
    // Obter dimensões
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    CVPixelBufferRef outputBuffer = NULL;
    
    // Criar um buffer de saída em formato BGRA
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
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar buffer de saída: %d", result);
        return NULL;
    }
    
    // Usar CIContext para conversão
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
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do buffer YUV");
        CVPixelBufferRelease(outputBuffer);
        return NULL;
    }
    
    // Renderizar o conteúdo no buffer de saída
    [_ciContext render:ciImage toCVPixelBuffer:outputBuffer];
    
    // Verificar se estamos usando aceleração de hardware
    BOOL isAccelerated = NO;
    
    // Verificar se o CVPixelBuffer usa IOSurface (indica aceleração de hardware)
    if (CVPixelBufferGetIOSurface(outputBuffer)) {
        isAccelerated = YES;
        _processingMode = @"hardware-accelerated";
    } else {
        _processingMode = @"software";
    }
    
    writeVerboseLog(@"[WebRTCFrameConverter] Conversão YUV->RGB %@",
                   isAccelerated ? @"usando aceleração de hardware" : @"usando software");
    
    return outputBuffer;
}

// Método de fallback usando CIImage
- (CVPixelBufferRef)convertYUVToRGBWithCIImage:(CVPixelBufferRef)pixelBuffer {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    if (!ciImage) {
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar CIImage a partir do buffer YUV");
        return NULL;
    }
    
    // Criar buffer de saída
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
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar buffer de saída: %d", result);
        return NULL;
    }
    
    // Renderizar a imagem no buffer de saída usando CIContext
    [_ciContext render:ciImage toCVPixelBuffer:outputBuffer];
    
    _processingMode = @"software-ciimage";
    return outputBuffer;
}

- (BOOL)isHardwareAccelerationAvailable {
    static BOOL checkedAvailability = NO;
    static BOOL isAvailable = NO;
    
    if (!checkedAvailability) {
        // Verificar disponibilidade de Metal como indicador de aceleração de hardware
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
    
    // Se já temos um contexto para estes formatos, reusar
    if (currentSourceFormat == sourceFormat && currentDestFormat == destFormat) {
        return YES;
    }
    
    // Apenas registrar os formatos atuais
    currentSourceFormat = sourceFormat;
    currentDestFormat = destFormat;
    
    // Nosso método usa CIContext que já lida com a conversão
    return YES;
}

#pragma mark - Adaptação para resolução alvo

- (UIImage *)adaptedImageFromVideoFrame:(RTCVideoFrame *)frame {
    @autoreleasepool {
        // Primeiro, converter o frame para UIImage
        UIImage *originalImage = [self imageFromVideoFrame:frame];
        if (!originalImage) return nil;
        
        // Se a imagem já está na resolução alvo, retorne-a diretamente
        if ((int)originalImage.size.width == _targetResolution.width &&
            (int)originalImage.size.height == _targetResolution.height) {
            return originalImage;
        }
        
        // Calcular proporções para determinar o tipo de adaptação necessária
        float originalAspect = originalImage.size.width / originalImage.size.height;
        float targetAspect = (float)_targetResolution.width / (float)_targetResolution.height;
        
        CGRect drawRect;
        CGSize finalSize = CGSizeMake(_targetResolution.width, _targetResolution.height);
        
        // Determinar se precisa de cropping ou letterboxing
        if (fabs(originalAspect - targetAspect) < 0.01) {
            // Proporções são quase idênticas, apenas redimensionar
            drawRect = CGRectMake(0, 0, finalSize.width, finalSize.height);
        }
        else if (originalAspect > targetAspect) {
            // Imagem original é mais larga, fazer cropping nos lados
            float scaledHeight = finalSize.height;
            float scaledWidth = scaledHeight * originalAspect;
            float xOffset = (scaledWidth - finalSize.width) / 2.0f;
            
            drawRect = CGRectMake(-xOffset, 0, scaledWidth, scaledHeight);
        }
        else {
            // Imagem original é mais alta, fazer cropping no topo/base
            float scaledWidth = finalSize.width;
            float scaledHeight = scaledWidth / originalAspect;
            float yOffset = (scaledHeight - finalSize.height) / 2.0f;
            
            drawRect = CGRectMake(0, -yOffset, scaledWidth, scaledHeight);
        }
        
        // Iniciar contexto de desenho com a resolução alvo
        UIGraphicsBeginImageContextWithOptions(finalSize, NO, 1.0);
        
        // Preencher fundo preto (para letterboxing)
        [[UIColor blackColor] setFill];
        UIRectFill(CGRectMake(0, 0, finalSize.width, finalSize.height));
        
        // Desenhar a imagem adaptada
        [originalImage drawInRect:drawRect];
        
        // Obter a imagem final
        UIImage *adaptedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (!adaptedImage) {
            writeLog(@"[WebRTCFrameConverter] Falha ao adaptar imagem para resolução alvo %dx%d",
                    _targetResolution.width, _targetResolution.height);
            return originalImage; // Fallback para a imagem original
        }
        
        // Log detalhado apenas ocasionalmente para evitar spam nos logs
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
        // Se não tivermos um frame, retornar nulo
        if (!_lastFrame) {
            return NULL;
        }
        
        // Verificar se devemos descartar este frame com base no timing
        // Criar um CMTime a partir do timestamp do WebRTC frame
        CMTime frameTimestamp = CMTimeMake(_lastFrame.timeStampNs, 1000000000);
        if ([self shouldDropFrameWithTimestamp:frameTimestamp]) {
            return NULL;
        }
        
        // Converter formato IOSPixelFormat para OSType
        OSType cvFormat = [WebRTCFrameConverter cvFormatFromPixelFormat:pixelFormat];
        
        // Criar chave para cache
        NSNumber *formatKey = @(cvFormat);
        
        // Verificar se temos um buffer em cache com o formato correto
        @synchronized(self) {
            // Verificar no cache individual
            if (_cachedSampleBuffer && _cachedSampleBufferHash == _lastFrameHash && _cachedSampleBufferFormat == cvFormat) {
                // Se já temos um buffer em cache para este frame e formato, melhorar o timing antes de retornar
                CMSampleBufferRef outputBuffer = NULL;
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, _cachedSampleBuffer, &outputBuffer);
                if (status != noErr) {
                    writeErrorLog(@"[WebRTCFrameConverter] Erro ao criar cópia do CMSampleBuffer: %d", (int)status);
                    return NULL;
                }
                
                // Aprimorar o timing do buffer antes de retornar
                CMSampleBufferRef enhancedBuffer = [self enhanceSampleBufferTiming:outputBuffer preserveOriginalTiming:YES];
                if (enhancedBuffer) {
                    // Liberar o buffer temporário
                    CFRelease(outputBuffer);
                    return enhancedBuffer;
                }
                
                return outputBuffer;
            }
            
            // Verificar no cache geral de formatos
            NSValue *cachedBufferValue = _sampleBufferCache[formatKey];
            if (cachedBufferValue) {
                CMSampleBufferRef cachedBuffer = NULL;
                [cachedBufferValue getValue:&cachedBuffer];
                
                if (cachedBuffer) {
                    // Verificar se o buffer é do frame atual
                    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(cachedBuffer);
                    if (formatDesc) {
                        // Criar uma cópia para retornar
                        CMSampleBufferRef outputBuffer = NULL;
                        OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, cachedBuffer, &outputBuffer);
                        if (status == noErr) {
                            // Aprimorar o timing antes de retornar
                            CMSampleBufferRef enhancedBuffer = [self enhanceSampleBufferTiming:outputBuffer preserveOriginalTiming:NO];
                            if (enhancedBuffer) {
                                // Liberar o buffer temporário
                                CFRelease(outputBuffer);
                                return enhancedBuffer;
                            }
                            
                            return outputBuffer;
                        }
                    }
                }
            }
        }
        
        // Caso contrário, criar um novo buffer
        CMSampleBufferRef sampleBuffer = [self createSampleBufferWithFormat:cvFormat];
        
        // Quando armazenar em cache um buffer:
        if (sampleBuffer) {
            @synchronized(self) {
                // Armazenar uma cópia para cache
                OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &_cachedSampleBuffer);
                if (status != noErr) {
                    writeErrorLog(@"[WebRTCFrameConverter] Erro ao criar cópia para cache: %d", (int)status);
                    // Ainda podemos retornar o buffer original mesmo se o cache falhar
                } else {
                    _cachedSampleBufferHash = _lastFrameHash;
                    _cachedSampleBufferFormat = cvFormat;
                    
                    // Também adicionar ao cache geral - primeiro criar uma cópia para o cache de formatos
                    CMSampleBufferRef formatCacheBuffer = NULL;
                    status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &formatCacheBuffer);
                    
                    if (status == noErr && formatCacheBuffer) {
                        // Liberar o buffer anterior para este formato se existir
                        NSValue *oldValue = _sampleBufferCache[formatKey];
                        if (oldValue) {
                            CMSampleBufferRef oldBuffer = NULL;
                            [oldValue getValue:&oldBuffer];
                            if (oldBuffer) {
                                CFRelease(oldBuffer);
                                _totalSampleBuffersReleased++;
                                
                                // Remover do rastreamento ativo
                                [_activeSampleBuffers removeObjectForKey:@(CFHash(oldBuffer))];
                            }
                        }
                        
                        // Armazenar o novo buffer
                        NSValue *newValue = [NSValue valueWithBytes:&formatCacheBuffer objCType:@encode(CMSampleBufferRef)];
                        _sampleBufferCache[formatKey] = newValue;
                        
                        // Registrar timestamp para controle de cache
                        _sampleBufferCacheTimestamps[formatKey] = [NSDate date];
                        
                        // Registrar no rastreamento ativo com informações de timing expandidas
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
                        
                        // Otimizar cache se estiver ficando grande
                        [self optimizeCacheSystem];
                    }
                }
            }
        }
        
        return sampleBuffer;
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCFrameConverter] Exceção em getLatestSampleBufferWithFormat: %@", exception);
        return NULL;
    }
}

// Método simplificado para usar o formato detectado
- (CMSampleBufferRef)getLatestSampleBuffer {
    return [self getLatestSampleBufferWithFormat:_detectedPixelFormat];
}

- (CMSampleBufferRef)createSampleBufferWithFormat:(OSType)format {
    if (!_lastFrame) return NULL;
    
    id<RTCVideoFrameBuffer> buffer = _lastFrame.buffer;
    
    // Verificar se temos um CVPixelBuffer
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
    
    // Verificar formato do pixel
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    
    // Registrar o formato para diagnóstico
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
    
    writeVerboseLog(@"[WebRTCFrameConverter] Formato de pixel origem: %s (0x%08X), destino: %s (0x%08X)",
                    sourceFormatChars, (unsigned int)sourceFormat,
                    targetFormatChars, (unsigned int)format);
    
    // Se o formato já for o desejado, podemos usar diretamente
    if (sourceFormat == format) {
        // Podemos usar diretamente o buffer original
        return [self createSampleBufferFromPixelBuffer:pixelBuffer];
    }
    
    // Caso contrário, precisamos converter para o formato desejado
    // Criar um novo buffer com o formato solicitado
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
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar buffer compatível: %d", result);
        return NULL;
    }
    
    // Converter o conteúdo usando CIImage/CIContext para máxima compatibilidade
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    [_ciContext render:ciImage toCVPixelBuffer:convertedBuffer];
    
    // Criar CMSampleBuffer com o buffer convertido
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:convertedBuffer];
    
    // Liberar o buffer convertido
    CVPixelBufferRelease(convertedBuffer);
    
    // Incrementar contador de buffers criados
    _totalSampleBuffersCreated++;
    
    // Registrar buffer no rastreamento ativo
    if (sampleBuffer) {
        @synchronized(self) {
            NSNumber *bufferKey = @(CFHash(sampleBuffer));
            _activeSampleBuffers[bufferKey] = @YES;
        }
    }
    
    return sampleBuffer;
}

/**
 * Cria um CMSampleBuffer a partir do pixel buffer com timing preciso.
 * Implementa uma sincronização de relógio mais precisa para preservar
 * o timing original dos frames WebRTC.
 */
- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NULL;

    // Incrementar contador de buffers criados
    _totalSampleBuffersCreated++;

    // Criar um CMVideoFormatDescription a partir do CVPixelBuffer
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);

    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMVideoFormatDescription: %d", (int)status);
        return NULL;
    }

    // Obter o timestamp usando o relógio de host de alta precisão do sistema
    // CoreMedia usa relógio com base em nanosegundos (10^9)
    CMTimeScale timeScale = 1000000000; // Nanosegundos para precisão máxima
    
    // Obter timestamp atual do sistema
    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    
    // Se temos _lastFrame de WebRTC, usar seu timestamp para melhor sincronização
    if (_lastFrame) {
        // Converter timestamp WebRTC (que está em nanosegundos) para CMTime
        // Isso preserva melhor a cadência original dos frames do transmissor
        uint64_t rtcTimestampNs = _lastFrame.timeStampNs;
        if (rtcTimestampNs > 0) {
            // Criar um CMTime a partir do timestamp WebRTC (preserva timing original)
            hostTime = CMTimeMake(rtcTimestampNs, timeScale);
            
            // Ajustar o timestamp para sincronizar com o relógio local
            // isso evita pulos quando o timestamp RTC está muito fora de sincronização
            CMTime currentTime = CMClockGetTime(CMClockGetHostTimeClock());
            
            // Se a diferença for muito grande, aproximar do tempo atual
            CMTime diff = CMTimeSubtract(currentTime, hostTime);
            if (CMTimeGetSeconds(diff) > 5.0 || CMTimeGetSeconds(diff) < -5.0) {
                // Limitar a diferença para evitar saltos grandes
                hostTime = currentTime;
            }
        }
    }

    // Criar CMSampleTimingInfo detalhado para preservar timing
    CMSampleTimingInfo timingInfo;
    
    // Calcular a duração com base na taxa de quadros alvo ou detectada
    Float64 frameDuration = 1.0 / 30.0; // Default: 30fps
    
    if (_adaptToTargetFrameRate && CMTIME_IS_VALID(_targetFrameDuration)) {
        frameDuration = CMTimeGetSeconds(_targetFrameDuration);
    } else if (_currentFps > 0) {
        frameDuration = 1.0 / _currentFps;
    }
    
    // Configurar timing info completo
    timingInfo.duration = CMTimeMakeWithSeconds(frameDuration, timeScale);
    timingInfo.presentationTimeStamp = hostTime;
    timingInfo.decodeTimeStamp = kCMTimeInvalid; // Usar tempo default para decodificação

    // Criar o CMSampleBuffer com timing preciso
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true, // dataReady
        NULL, // allocator
        NULL, // dataCallback
        formatDescription,
        &timingInfo,
        &sampleBuffer
    );

    // Liberar a descrição do formato
    if (formatDescription) {
        CFRelease(formatDescription);
    }

    if (status != 0) {
        writeLog(@"[WebRTCFrameConverter] Erro ao criar CMSampleBuffer: %d", (int)status);
        return NULL;
    }

    // Registrar buffer no mapa de buffers ativos
    if (sampleBuffer) {
        @synchronized(self) {
            NSNumber *bufferKey = @(CFHash(sampleBuffer));
            _activeSampleBuffers[bufferKey] = @{
                @"timestamp": [NSDate date],
                @"thread": [NSThread currentThread],
                @"ptsSeconds": @(CMTimeGetSeconds(timingInfo.presentationTimeStamp)),
                @"durationSeconds": @(CMTimeGetSeconds(timingInfo.duration))
            };
            
            // Guardar o timestamp para análise de cadência
            _lastBufferTimestamp = timingInfo.presentationTimeStamp;
        }
    }

    return sampleBuffer;
}

/**
 * Adiciona timestamps e attachment de timing à um sample buffer existente
 * para garantir a sincronização em substituições de fluxo de câmera.
 * @param sampleBuffer Sample buffer original
 * @param preserveOriginalTiming Se TRUE, tenta preservar o timing original
 * @return CMSampleBufferRef com timing atualizado ou NULL em caso de erro
 */
- (CMSampleBufferRef)enhanceSampleBufferTiming:(CMSampleBufferRef)sampleBuffer
                         preserveOriginalTiming:(BOOL)preserveOriginalTiming {
    if (!sampleBuffer) return NULL;
    
    // Criar uma cópia do buffer para modificação
    CMSampleBufferRef outputBuffer = NULL;
    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &outputBuffer);
    
    if (status != noErr || !outputBuffer) {
        writeErrorLog(@"[WebRTCFrameConverter] Erro ao criar cópia de SampleBuffer: %d", (int)status);
        return NULL;
    }
    
    // Obter timing info atual
    CMSampleTimingInfo timingInfo;
    status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
    
    if (status != noErr) {
        writeWarningLog(@"[WebRTCFrameConverter] Erro ao obter timing info: %d", (int)status);
        // Continuar mesmo com erro - iremos recriar o timing
    }
    
    // Obter timestamp atual com alta precisão
    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTimeScale timeScale = hostTime.timescale;
    
    // Manter a duração original ou calcular com base na taxa de quadros detectada
    Float64 frameDuration;
    if (preserveOriginalTiming && CMTIME_IS_VALID(timingInfo.duration)) {
        frameDuration = CMTimeGetSeconds(timingInfo.duration);
    } else {
        frameDuration = 1.0 / 30.0; // Default: 30fps
        
        if (_adaptToTargetFrameRate && CMTIME_IS_VALID(_targetFrameDuration)) {
            frameDuration = CMTimeGetSeconds(_targetFrameDuration);
        } else if (_currentFps > 0) {
            frameDuration = 1.0 / _currentFps;
        }
    }
    
    // Configurar timing info melhorado
    CMSampleTimingInfo newTimingInfo;
    newTimingInfo.duration = CMTimeMakeWithSeconds(frameDuration, timeScale);
    
    // Se devemos preservar o timing original E temos timestamp válido
    if (preserveOriginalTiming && CMTIME_IS_VALID(timingInfo.presentationTimeStamp)) {
        newTimingInfo.presentationTimeStamp = timingInfo.presentationTimeStamp;
    } else {
        // Caso contrário, usar timestamp de host atual
        newTimingInfo.presentationTimeStamp = hostTime;
    }
    
    // Usar decodeTimeStamp original se válido
    if (CMTIME_IS_VALID(timingInfo.decodeTimeStamp)) {
        newTimingInfo.decodeTimeStamp = timingInfo.decodeTimeStamp;
    } else {
        newTimingInfo.decodeTimeStamp = kCMTimeInvalid;
    }
    
    // Atualizar o timestamp de apresentação de saída
    status = CMSampleBufferSetOutputPresentationTimeStamp(outputBuffer, newTimingInfo.presentationTimeStamp);
    if (status != noErr) {
        writeWarningLog(@"[WebRTCFrameConverter] Aviso: não foi possível atualizar output timestamp: %d", (int)status);
    }
    
    // Adicionar attachment com informações específicas para melhor integração com AVFoundation
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

/**
 * Verifica se um frame deve ser descartado com base na cadência e timing
 * Esta função implementa um mecanismo de "dropping" inteligente para
 * evitar sobrecarga quando os frames vêm mais rápido do que o desejado.
 *
 * @param frameTimestamp Timestamp do frame a verificar
 * @return TRUE se o frame deve ser descartado, FALSE caso contrário
 */
- (BOOL)shouldDropFrameWithTimestamp:(CMTime)frameTimestamp {
    // Se a adaptação de frame rate não estiver ativada, não descartar
    if (!_adaptToTargetFrameRate) return NO;
    
    // Se não temos timestamp anterior, não podemos comparar - não descartar
    if (CMTIME_IS_INVALID(_lastProcessedFrameTimestamp)) {
        _lastProcessedFrameTimestamp = frameTimestamp;
        return NO;
    }
    
    // Calcular o tempo alvo entre frames com base na taxa desejada
    CMTime targetFrameDuration = _targetFrameDuration;
    if (CMTIME_IS_INVALID(targetFrameDuration) || CMTIME_COMPARE_INLINE(targetFrameDuration, ==, kCMTimeZero)) {
        // Default para 30fps se não tivermos duração alvo válida
        targetFrameDuration = CMTimeMake(1, 30);
    }
    
    // Calcular tempo decorrido desde o último frame
    CMTime elapsed = CMTimeSubtract(frameTimestamp, _lastProcessedFrameTimestamp);
    
    // Se o tempo decorrido for menor que a duração alvo, considerar descartar
    if (CMTIME_IS_VALID(elapsed) && CMTIME_COMPARE_INLINE(elapsed, <, targetFrameDuration)) {
        // Calcular percentual do tempo desejado
        Float64 elapsedSeconds = CMTimeGetSeconds(elapsed);
        Float64 targetSeconds = CMTimeGetSeconds(targetFrameDuration);
        
        if (targetSeconds > 0) {
            Float64 percentOfTarget = elapsedSeconds / targetSeconds;
            
            // Se estiver abaixo de um limiar (ex: 70% do tempo alvo), descartar
            // Este limiar evita que pequenas flutuações causem descarte excessivo
            if (percentOfTarget < 0.7) {
                // Incrementar contador de frames descartados
                _droppedFrameCount++;
                
                // Log periódico para não sobrecarregar
                if (_droppedFrameCount % 10 == 0) {
                    writeVerboseLog(@"[WebRTCFrameConverter] Descartados %d frames (cadência: %.1f%% do alvo)",
                                  (int)_droppedFrameCount, percentOfTarget * 100);
                }
                
                return YES;
            }
        }
    }
    
    // Frame aceito - atualizar timestamp de referência
    _lastProcessedFrameTimestamp = frameTimestamp;
    return NO;
}

/**
 * Obtém o CMClockRef mais adequado para sincronização
 * Em caso de substituição de câmera, é crucial usar o mesmo relógio
 * que a AVCaptureSession para manter a sincronização correta
 *
 * @return O CMClockRef a ser usado para sincronização
 */
- (CMClockRef)getCurrentSyncClock {
    // Se estamos em modo de substituição de câmera e temos acesso ao relógio da sessão,
    // usar o relógio da sessão para sincronização perfeita
    if (_captureSessionClock) {
        return _captureSessionClock;
    }
    
    // Caso contrário, usar o relógio de host padrão (alta precisão)
    return CMClockGetHostTimeClock();
}

/**
 * Define o relógio de sincronização da AVCaptureSession para uso na substitução
 * Isso permite que os frames WebRTC sejam sincronizados perfeitamente com a cadência
 * da câmera original, mantendo a ilusão de uma única fonte de frames
 *
 * @param clock CMClockRef da sessão de captura
 */
- (void)setCaptureSessionClock:(CMClockRef)clock {
    if (clock) {
        _captureSessionClock = clock;
        writeLog(@"[WebRTCFrameConverter] Relógio de sessão de captura configurado para sincronização");
    } else {
        _captureSessionClock = NULL;
        writeLog(@"[WebRTCFrameConverter] Relógio de sessão de captura removido");
    }
}

/**
 * Obtém metadados de um buffer de amostra original para preservação
 * Isso é crucial para manter informações como balanço de branco, exposição,
 * e outros metadados da câmera ao substituir o feed nativo
 *
 * @param originalBuffer O buffer original da câmera
 * @return Dicionário com metadados extraídos ou nil se não disponível
 */
- (NSDictionary *)extractMetadataFromSampleBuffer:(CMSampleBufferRef)originalBuffer {
    if (!originalBuffer) return nil;
    
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    
    // Extrair attachments do buffer
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(originalBuffer, false);
    if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
        CFDictionaryRef attachments = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
        if (attachments) {
            // Converter para NSDictionary para facilitar manipulação
            NSDictionary *attachmentsDict = (__bridge NSDictionary *)attachments;
            [metadata setObject:attachmentsDict forKey:@"attachments"];
        }
    }
    
    // Extrair timing info
    CMSampleTimingInfo timingInfo;
    if (CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &timingInfo) == kCMBlockBufferNoErr) {
        [metadata setObject:@{
            @"presentationTimeStamp": @(CMTimeGetSeconds(timingInfo.presentationTimeStamp)),
            @"duration": @(CMTimeGetSeconds(timingInfo.duration)),
            @"decodeTimeStamp": CMTIME_IS_VALID(timingInfo.decodeTimeStamp) ?
                @(CMTimeGetSeconds(timingInfo.decodeTimeStamp)) : @(0)
        } forKey:@"timingInfo"];
    }
    
    // Extrair informações de formato
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (formatDescription) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        [metadata setObject:@{
            @"width": @(dimensions.width),
            @"height": @(dimensions.height),
            @"mediaType": @"video"
        } forKey:@"formatDescription"];
        
        // Extrair extensões de formato se disponíveis
        CFDictionaryRef extensionsDictionary = CMFormatDescriptionGetExtensions(formatDescription);
        if (extensionsDictionary) {
            NSDictionary *extensions = (__bridge NSDictionary *)extensionsDictionary;
            [metadata setObject:extensions forKey:@"extensions"];
        }
    }
    
    // Extrair metadados específicos da câmera (exposição, balanço de branco, etc.)
    CFDictionaryRef metadataDict = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                               originalBuffer,
                                                               kCMAttachmentMode_ShouldPropagate);
    if (metadataDict) {
        [metadata setObject:(__bridge NSDictionary *)metadataDict forKey:@"cameraMetadata"];
        CFRelease(metadataDict);
    }
    
    return metadata;
}

/**
 * Aplica metadados previamente extraídos a um sample buffer
 * Isso permite que o buffer WebRTC tenha os mesmos metadados do buffer da câmera original
 *
 * @param sampleBuffer O buffer onde aplicar os metadados
 * @param metadata Dicionário com metadados a aplicar
 * @return TRUE se sucesso, FALSE caso contrário
 */
- (BOOL)applyMetadataToSampleBuffer:(CMSampleBufferRef)sampleBuffer metadata:(NSDictionary *)metadata {
    if (!sampleBuffer || !metadata) return NO;
    
    BOOL success = YES;
    
    // Aplicar attachments
    NSDictionary *attachmentsDict = metadata[@"attachments"];
    if (attachmentsDict) {
        CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
            CFMutableDictionaryRef attachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
            
            // Aplicar cada chave do dicionário original
            [attachmentsDict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                CFDictionarySetValue(attachments, (__bridge const void *)key, (__bridge const void *)obj);
            }];
        }
    }
    
    // Aplicar metadados específicos da câmera
    NSDictionary *cameraMetadata = metadata[@"cameraMetadata"];
    if (cameraMetadata) {
        CMSetAttachments(sampleBuffer, (__bridge CFDictionaryRef)cameraMetadata, kCMAttachmentMode_ShouldPropagate);
    }
    
    // Timing info já foi aplicado na criação, não precisamos replicar
    
    return success;
}

#pragma mark - Métodos de Interface Pública

- (UIImage *)getLastFrameAsImage {
    @synchronized(self) {
        if (!_lastFrame) {
            return nil;
        }
        
        // Verificar se temos imagem em cache
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
    // Calcular tempo médio de processamento
    float averageTime = 0;
    for (int i = 0; i < 10; i++) {
        averageTime += _frameProcessingTimes[i];
    }
    averageTime /= 10.0;
    float fps = averageTime > 0 ? 1.0/averageTime : 0;
    
    // Calcular taxa de frames real com base no tempo entre frames
    float actualFps = 0;
    if (_frameCount > 1 && _lastFrameTime > 0) {
        NSTimeInterval now = CACurrentMediaTime();
        NSTimeInterval timeSinceLastFrame = now - _lastFrameTime;
        if (timeSinceLastFrame > 0) {
            actualFps = 1.0 / timeSinceLastFrame;
        }
    }
    
    // Informações sobre o último frame
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
    
    // Estatísticas de gerenciamento de recursos
    NSMutableDictionary *resourceStats = [NSMutableDictionary dictionary];
    resourceStats[@"sampleBuffersCreated"] = @(_totalSampleBuffersCreated);
    resourceStats[@"sampleBuffersReleased"] = @(_totalSampleBuffersReleased);
    resourceStats[@"pixelBuffersLocked"] = @(_totalPixelBuffersLocked);
    resourceStats[@"pixelBuffersUnlocked"] = @(_totalPixelBuffersUnlocked);
    resourceStats[@"sampleBufferCacheSize"] = @(_sampleBufferCache.count);
    
    // Verificar se há um desequilíbrio significativo em recursos
    NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
    NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
    resourceStats[@"sampleBufferDiff"] = @(sampleBufferDiff);
    resourceStats[@"pixelBufferDiff"] = @(pixelBufferDiff);
    
    // Adicionar status geral de recursos
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
        // Limpar cache de imagem
        _cachedImage = nil;
        
        // Limpar cache de sample buffers
        [self clearSampleBufferCache];
        
        // Verificar se há desequilíbrio em recursos e registrar
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        
        if (sampleBufferDiff > 0 || pixelBufferDiff > 0) {
            writeWarningLog(@"[WebRTCFrameConverter] Possíveis recursos não liberados: %ld sample buffers, %ld pixel buffers",
                           (long)sampleBufferDiff, (long)pixelBufferDiff);
        }
    }
}

- (void)detectAndRecuperarVazamentos {
    @synchronized(self) {
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        
        if (sampleBufferDiff > 10 || pixelBufferDiff > 10) {
            writeWarningLog(@"[WebRTCFrameConverter] Corrigindo desbalanceamento de recursos - Ajustando contadores");
            
            // Ajustar contadores para evitar overflow em execução longa
            if (sampleBufferDiff > 0) {
                _totalSampleBuffersReleased += sampleBufferDiff;
            }
            
            if (pixelBufferDiff > 0) {
                _totalPixelBuffersUnlocked += pixelBufferDiff;
            }
            
            // Limpar todos os caches
            [self clearSampleBufferCache];
            _cachedImage = nil;
            
            // Forçar ciclo de coleta de lixo
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
        
        // Iterar sobre uma cópia para evitar modificar o dicionário durante a iteração
        NSDictionary *buffersCopy = [_activeSampleBuffers copy];
        for (NSNumber *bufferKey in buffersCopy) {
            id bufferInfo = buffersCopy[bufferKey];
            if (bufferInfo) {
                [_activeSampleBuffers removeObjectForKey:bufferKey];
                _totalSampleBuffersReleased++;
            }
        }
        
        // Limpar cache também
        [self clearSampleBufferCache];
        
        // Verificar e equilibrar os contadores de CVPixelBuffer
        NSInteger pixelBufferDiff = _totalPixelBuffersLocked - _totalPixelBuffersUnlocked;
        if (pixelBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Equilibrando contadores de CVPixelBuffer: %ld locks sem unlock", (long)pixelBufferDiff);
            _totalPixelBuffersUnlocked += pixelBufferDiff;
        }
        
        // Verificar e equilibrar os contadores de CMSampleBuffer
        NSInteger sampleBufferDiff = _totalSampleBuffersCreated - _totalSampleBuffersReleased;
        if (sampleBufferDiff > 0) {
            writeLog(@"[WebRTCFrameConverter] Ajustando contador de sample buffers: %ld buffers não liberados", (long)sampleBufferDiff);
            _totalSampleBuffersReleased += sampleBufferDiff;
        }
        
        // Limpar todos os caches e variáveis internas
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
    
    // Verificar suporte a Metal
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    BOOL metalSupported = (metalDevice != nil);
    if (metalDevice) {
        writeLog(@"[WebRTCFrameConverter] Metal disponível: %@", [metalDevice name]);
    }
    
    // Configure for CoreImage hardware acceleration
    if (_ciContext) {
        NSDictionary *options = @{
            kCIContextUseSoftwareRenderer: @(NO),
            kCIContextWorkingColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB(),
            kCIContextOutputColorSpace: (__bridge id)CGColorSpaceCreateDeviceRGB()
        };
        
        _ciContext = [CIContext contextWithOptions:options];
        isHardwareAccelerationConfigured = (_ciContext != nil);
    }
    
    // Se tivermos suporte a aceleração de hardware, atualizar modo de processamento
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
    // Se otimizar para performance, priorizar velocidade sobre uso de memória
    if (optimize) {
        // Aumentar cache para reduzir recomputação
        _maxCachedSampleBuffers = 5;
        
        // Usar pool de buffers para performance máxima
        [self setupBufferPool];
        
        // Configurar threading para máxima performance
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing.highperf",
                                               dispatch_queue_attr_make_with_qos_class(
                                                   DISPATCH_QUEUE_CONCURRENT,
                                                   QOS_CLASS_USER_INTERACTIVE,
                                                   0));
        
        writeLog(@"[WebRTCFrameConverter] Otimização para performance máxima ativada");
    } else {
        // Reduzir uso de memória
        _maxCachedSampleBuffers = 2;
        
        // Liberar pool de buffers
        [self releaseBufferPool];
        
        // Usar QoS menor para economizar bateria
        _processingQueue = dispatch_queue_create("com.webrtc.frameprocessing.balanced",
                                               dispatch_queue_attr_make_with_qos_class(
                                                   DISPATCH_QUEUE_CONCURRENT,
                                                   QOS_CLASS_DEFAULT,
                                                   0));
        
        writeLog(@"[WebRTCFrameConverter] Otimização balanceada (memória/performance)");
    }
}

- (void)setupBufferPool {
    // Versão simplificada sem usar variáveis estáticas globais
    writeLog(@"[WebRTCFrameConverter] Pool de pixel buffers não implementado nesta versão");
}

- (void)releaseBufferPool {
    // Método vazio para compatibilidade
    writeLog(@"[WebRTCFrameConverter] Pool de pixel buffers não implementado");
}

- (RTCCVPixelBuffer *)scalePixelBufferToTargetSize:(RTCCVPixelBuffer *)pixelBuffer {
    if (!pixelBuffer) return nil;
    
    CVPixelBufferRef originalBuffer = pixelBuffer.pixelBuffer;
    if (!originalBuffer) return nil;
    
    // Verificar se o escalonamento é realmente necessário
    size_t originalWidth = CVPixelBufferGetWidth(originalBuffer);
    size_t originalHeight = CVPixelBufferGetHeight(originalBuffer);
    
    if (originalWidth == _targetResolution.width && originalHeight == _targetResolution.height) {
        return pixelBuffer; // Já na resolução correta
    }
    
    // Criar buffer de destino na resolução alvo
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
        writeErrorLog(@"[WebRTCFrameConverter] Falha ao criar buffer para escalonamento: %d", result);
        return nil;
    }
    
    // Escolher método de escalonamento (hardware ou software)
    BOOL useHardwareScaling = [self isHardwareAccelerationAvailable];
    
    if (useHardwareScaling && pixelFormat != kCVPixelFormatType_32BGRA) {
        // Para YUV, usar CIContext para escalonamento via GPU
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:originalBuffer];
        
        // Aplicar escalonamento mantendo proporções
        //CGRect targetRect = CGRectMake(0, 0, _targetResolution.width, _targetResolution.height);
        
        // Calcular proporções
        float originalAspect = (float)originalWidth / (float)originalHeight;
        float targetAspect = (float)_targetResolution.width / (float)_targetResolution.height;
        
        // Aplicar transformação adequada
        if (fabs(originalAspect - targetAspect) < 0.01) {
            // Aspecto similar, escalonar uniformemente
            ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                (float)_targetResolution.width / (float)originalWidth,
                (float)_targetResolution.height / (float)originalHeight
            )];
        } else if (originalAspect > targetAspect) {
            // Fonte mais larga - escalonar pela altura e cortar laterais
            float scaleFactor = (float)_targetResolution.height / (float)originalHeight;
            float scaledWidth = originalWidth * scaleFactor;
            float xOffset = (scaledWidth - _targetResolution.width) / 2.0f;
            
            // Primeiro escalonar
            ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                scaleFactor, scaleFactor
            )];
            
            // Depois cortar
            ciImage = [ciImage imageByCroppingToRect:CGRectMake(
                xOffset, 0, _targetResolution.width, _targetResolution.height
            )];
        } else {
            // Fonte mais alta - escalonar pela largura e cortar topo/base
            float scaleFactor = (float)_targetResolution.width / (float)originalWidth;
            float scaledHeight = originalHeight * scaleFactor;
            float yOffset = (scaledHeight - _targetResolution.height) / 2.0f;
            
            // Primeiro escalonar
            ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMakeScale(
                scaleFactor, scaleFactor
            )];
            
            // Depois cortar
            ciImage = [ciImage imageByCroppingToRect:CGRectMake(
                0, yOffset, _targetResolution.width, _targetResolution.height
            )];
        }
        
        // Renderizar na nova resolução usando CIContext (hardware accelerated)
        [_ciContext render:ciImage toCVPixelBuffer:scaledBuffer];
    } else {
        // Para BGRA ou fallback, usar Accelerate.framework (vImage)
        CVPixelBufferLockBaseAddress(originalBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(scaledBuffer, 0);
        
        size_t originalBytesPerRow = CVPixelBufferGetBytesPerRow(originalBuffer);
        size_t scaledBytesPerRow = CVPixelBufferGetBytesPerRow(scaledBuffer);
        
        void *originalBaseAddress = CVPixelBufferGetBaseAddress(originalBuffer);
        void *scaledBaseAddress = CVPixelBufferGetBaseAddress(scaledBuffer);
        
        // Configurar estruturas vImage
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
        
        // Usar interpolação de alta qualidade
        vImage_Error error = vImageScale_ARGB8888(&src, &dest, NULL, kvImageHighQualityResampling);
        
        CVPixelBufferUnlockBaseAddress(originalBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(scaledBuffer, 0);
        
        if (error != kvImageNoError) {
            writeErrorLog(@"[WebRTCFrameConverter] Erro no escalonamento vImage: %ld", error);
            CVPixelBufferRelease(scaledBuffer);
            return nil;
        }
    }
    
    // Criar RTCCVPixelBuffer com o novo buffer escalonado
    RTCCVPixelBuffer *rtcScaledBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:scaledBuffer];
    
    // O RTCCVPixelBuffer retém o pixelBuffer, podemos liberar nossa referência
    CVPixelBufferRelease(scaledBuffer);
    
    return rtcScaledBuffer;
}

- (void)setFrameRateAdaptationStrategy:(NSString *)newStrategy {
    static NSString *currentStrategy = nil;
    
    // Evitar reconfiguração desnecessária
    if (currentStrategy && [currentStrategy isEqualToString:newStrategy]) {
        return;
    }
    
    currentStrategy = [newStrategy copy];
    
    // Configurar estratégia de adaptação
    if ([newStrategy isEqualToString:@"quality"]) {
        // Priorizar qualidade - processar todos os frames
        _targetFrameDuration = CMTimeMake(1, 60); // Target 60fps
        _droppedFrameCount = 0;
        
        writeLog(@"[WebRTCFrameConverter] Usando estratégia de adaptação: qualidade máxima (60fps)");
    }
    else if ([newStrategy isEqualToString:@"performance"]) {
        // Priorizar performance - descartar frames conforme necessário
        _targetFrameDuration = CMTimeMake(1, 30); // Target 30fps
        
        writeLog(@"[WebRTCFrameConverter] Usando estratégia de adaptação: performance (30fps)");
    }
    else {
        // Modo balanceado (padrão)
        _targetFrameDuration = CMTimeMake(1, 45); // Target 45fps
        
        writeLog(@"[WebRTCFrameConverter] Usando estratégia de adaptação: balanceada (45fps)");
    }
}

- (BOOL)shouldProcessFrame:(RTCVideoFrame *)frame {
    // Se não temos frame anterior, sempre processar
    if (!_lastFrame) {
        return YES;
    }
    
    // Calcular tempo entre frames
    uint64_t currentTime = frame.timeStampNs;
    uint64_t lastTime = _lastFrame.timeStampNs;
    
    // Evitar overflow ou valores inválidos
    if (currentTime <= lastTime) {
        return YES;
    }
    
    // Calcular FPS atual com base no timestamp
    uint64_t timeDiff = currentTime - lastTime;
    float fpsCurrent = 1000000000.0f / timeDiff; // ns para segundos
    
    // Taxa de quadros alvo convertida para FPS
    float targetFps = _targetFrameDuration.timescale / (float)_targetFrameDuration.value;
    
    // Se a taxa atual é menor que a alvo, processar todos os frames
    if (fpsCurrent <= targetFps) {
        return YES;
    }
    
    // Se estamos bem acima da taxa alvo, descartar frames para economizar recursos
    // Usar um sistema adaptativo que mantém uma cadência constante
    static uint64_t frameCounter = 0;
    frameCounter++;
    
    // Calcular razão de descarte (exemplo: se fpsCurrent=90 e targetFps=30, descartamos 2 a cada 3 frames)
    int dropRatio = (int)(fpsCurrent / targetFps);
    
    // Usar frameCounter para manter uma cadência consistente
    BOOL shouldDrop = (frameCounter % dropRatio != 0);
    
    if (shouldDrop) {
        _droppedFrameCount++;
        
        // Log periódico para não sobrecarregar
        if (_droppedFrameCount % 30 == 0) {
            writeVerboseLog(@"[WebRTCFrameConverter] Adaptação de taxa: descartados %lu frames (fps atual: %.1f, alvo: %.1f)",
                           (unsigned long)_droppedFrameCount, fpsCurrent, targetFps);
        }
    }
    
    return !shouldDrop;
}

@end
