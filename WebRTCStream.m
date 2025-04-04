#import "WebRTCStream.h"
#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

@implementation WebRTCStream {
    BOOL _streamActive;
    dispatch_queue_t _processingQueue;
    CMSampleBufferRef _lastProcessedBuffer;
    NSMutableArray *_previewLayers;
}

+ (instancetype)sharedInstance {
    static WebRTCStream *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _streamActive = NO;
        _processingQueue = dispatch_queue_create("com.webrtc.stream", DISPATCH_QUEUE_SERIAL);
        _lastProcessedBuffer = nil;
        _previewLayers = [NSMutableArray array];
        
        // Iniciar timer para atualização contínua das camadas
        [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                         target:self
                                       selector:@selector(updatePreviewLayers)
                                       userInfo:nil
                                        repeats:YES];
    }
    return self;
}

- (void)dealloc {
    if (_lastProcessedBuffer) {
        CFRelease(_lastProcessedBuffer);
        _lastProcessedBuffer = nil;
    }
}

- (void)registerPreviewLayer:(AVCaptureVideoPreviewLayer *)layer {
    if (![_previewLayers containsObject:layer]) {
        [_previewLayers addObject:layer];
        writeLog(@"[WebRTCStream] Nova camada de preview registrada, total: %lu", (unsigned long)_previewLayers.count);
    }
}

- (void)setActiveStream:(BOOL)active {
    _streamActive = active;
    writeLog(@"[WebRTCStream] Stream ativo: %@", active ? @"SIM" : @"NÃO");
    
    // Mascarar/desmascarar as camadas de preview
    [self updatePreviewLayerMasks];
}

- (void)updatePreviewLayerMasks {
    for (AVCaptureVideoPreviewLayer *layer in _previewLayers) {
        // Verifica se já existe uma máscara preta para esta camada
        CALayer *maskLayer = nil;
        for (CALayer *sublayer in layer.sublayers) {
            if ([sublayer.name isEqualToString:@"WebRTCMask"]) {
                maskLayer = sublayer;
                break;
            }
        }
        
        // Se não existe e queremos mascarar, cria uma nova
        if (!maskLayer && _streamActive) {
            maskLayer = [CALayer layer];
            maskLayer.name = @"WebRTCMask";
            maskLayer.backgroundColor = [UIColor blackColor].CGColor;
            maskLayer.frame = layer.bounds;
            [layer addSublayer:maskLayer];
            writeLog(@"[WebRTCStream] Máscara adicionada para camada");
        }
        
        // Atualiza a opacidade da máscara
        if (maskLayer) {
            maskLayer.opacity = _streamActive ? 1.0 : 0.0;
            maskLayer.frame = layer.bounds;
        }
    }
}

- (BOOL)isStreamActive {
    return _streamActive;
}

- (WebRTCManager *)getWebRTCManager {
    // Procura por uma instância do FloatingWindow nas janelas ativas
    NSArray *windows = UIApplication.sharedApplication.windows;
    for (UIWindow *window in windows) {
        if ([window isKindOfClass:NSClassFromString(@"FloatingWindow")]) {
            FloatingWindow *floatingWindow = (FloatingWindow *)window;
            return floatingWindow.webRTCManager;
        }
    }
    
    // Se não encontrar nas janelas, tenta o FloatingWindow global
    return [NSClassFromString(@"FloatingWindow") valueForKey:@"webRTCManager"];
}

- (void)updatePreviewLayers {
    if (!_streamActive) {
        return;
    }
    
    WebRTCManager *manager = [self getWebRTCManager];
    if (!manager || !manager.isReceivingFrames) {
        return;
    }
    
    // Obtém o buffer atual do WebRTC
    CMSampleBufferRef webRTCBuffer = [manager.frameConverter getLatestSampleBuffer];
    if (!webRTCBuffer) {
        return;
    }
    
    // Atualiza todas as camadas de preview registradas
    for (AVCaptureVideoPreviewLayer *layer in _previewLayers) {
        // Encontra ou cria a camada de preview WebRTC para esta camada
        AVSampleBufferDisplayLayer *displayLayer = nil;
        for (CALayer *sublayer in layer.sublayers) {
            if ([sublayer isKindOfClass:[AVSampleBufferDisplayLayer class]] &&
                [sublayer.name isEqualToString:@"WebRTCPreview"]) {
                displayLayer = (AVSampleBufferDisplayLayer *)sublayer;
                break;
            }
        }
        
        if (!displayLayer) {
            displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
            displayLayer.name = @"WebRTCPreview";
            displayLayer.frame = layer.bounds;
            displayLayer.videoGravity = layer.videoGravity;
            [layer addSublayer:displayLayer];
            writeLog(@"[WebRTCStream] Nova camada de preview adicionada");
        }
        
        // Atualiza a posição e tamanho
        displayLayer.frame = layer.bounds;
        
        // Enfileira o buffer apenas se a camada estiver pronta
        if (displayLayer.readyForMoreMediaData) {
            [displayLayer flush];
            [displayLayer enqueueSampleBuffer:webRTCBuffer];
        }
    }
}

- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originalBuffer {
    if (!_streamActive) {
        return NULL;
    }
    
    WebRTCManager *manager = [self getWebRTCManager];
    if (!manager || !manager.isReceivingFrames) {
        return NULL;
    }
    
    CMSampleBufferRef webRTCBuffer = [manager.frameConverter getLatestSampleBuffer];
    if (!webRTCBuffer) {
        return NULL;
    }
    
    if (!originalBuffer) {
        return webRTCBuffer;
    }
    
    // Se temos um buffer original, precisamos transferir propriedades de tempo
    __block CMSampleBufferRef resultBuffer = NULL;
    
    dispatch_sync(_processingQueue, ^{
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(webRTCBuffer);
        if (!pixelBuffer) {
            writeLog(@"[WebRTCStream] Pixel buffer não encontrado");
            return;
        }
        
        // Extrai informações de tempo do buffer original
        CMSampleTimingInfo timing;
        OSStatus status = CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &timing);
        if (status != noErr) {
            writeLog(@"[WebRTCStream] Erro ao obter timing: %d", (int)status);
            // Em caso de erro, usa valores padrão
            timing.duration = kCMTimeInvalid;
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originalBuffer);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }
        
        // Cria formato de vídeo para o novo buffer
        CMVideoFormatDescriptionRef videoDesc = NULL;
        status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoDesc);
        
        if (status != noErr) {
            writeLog(@"[WebRTCStream] Erro ao criar descrição de formato: %d", (int)status);
            return;
        }
        
        // Cria buffer final
        status = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            true,
            NULL,
            NULL,
            videoDesc,
            &timing,
            &resultBuffer
        );
        
        CFRelease(videoDesc);
        
        if (status != noErr) {
            writeLog(@"[WebRTCStream] Erro ao criar buffer final: %d", (int)status);
            return;
        }
        
        // Libera qualquer buffer anterior
        if (_lastProcessedBuffer) {
            CFRelease(_lastProcessedBuffer);
        }
        
        // Armazena o novo buffer
        _lastProcessedBuffer = resultBuffer;
        CFRetain(_lastProcessedBuffer);
    });
    
    return resultBuffer ? resultBuffer : webRTCBuffer;
}

@end
