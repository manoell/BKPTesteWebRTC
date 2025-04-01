#import "WebRTCBufferInjector.h"
#import "FloatingWindow.h"
#import "logger.h"
#import <objc/runtime.h>

// Chave associada para metadata dos buffers
static void *kBufferOriginKey = &kBufferOriginKey;

@implementation WebRTCBufferInjector

#pragma mark - Singleton Implementation

+ (instancetype)sharedInstance {
    static WebRTCBufferInjector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _active = NO;
        _configured = NO;
        _originalDelegates = [NSMutableDictionary dictionary];
        _webRTCManager = [WebRTCManager sharedInstance];
        _frameConverter = [[WebRTCFrameConverter alloc] init];
        _currentCameraPosition = AVCaptureDevicePositionUnspecified;
        _frameCount = 0;
        _replacedFrameCount = 0;
        
        writeLog(@"[WebRTCBufferInjector] Inicializado");
    }
    return self;
}

#pragma mark - Configuration

- (void)configureWithSession:(AVCaptureSession *)session {
    if (self.configured && self.captureSession == session) {
        writeLog(@"[WebRTCBufferInjector] Já configurado para esta sessão, ignorando chamada duplicada");
        return;
    }
    
    // Armazenar referência da sessão
    self.captureSession = session;
    
    // Configurar WebRTCManager se necessário
    if (!self.webRTCManager) {
        self.webRTCManager = [WebRTCManager sharedInstance];
    }
    
    // Configurar frameConverter
    [self.frameConverter reset];
    
    // Detectar posição atual da câmera
    for (AVCaptureInput *input in session.inputs) {
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
            AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
            if ([deviceInput.device hasMediaType:AVMediaTypeVideo]) {
                self.currentCameraPosition = deviceInput.device.position;
                
                writeLog(@"[WebRTCBufferInjector] Câmera detectada: %@ (posição: %@, ID: %@)",
                       deviceInput.device.localizedName,
                       self.currentCameraPosition == AVCaptureDevicePositionBack ? @"traseira" :
                       (self.currentCameraPosition == AVCaptureDevicePositionFront ? @"frontal" : @"desconhecida"),
                       deviceInput.device.uniqueID);
                
                // Se a sessão estiver configurada para um formato específico, tentar detectá-lo
                if ([deviceInput.device respondsToSelector:@selector(activeFormat)]) {
                    AVCaptureDeviceFormat *format = deviceInput.device.activeFormat;
                    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                    
                    writeLog(@"[WebRTCBufferInjector] Formato ativo: %dx%d, %@ fps",
                           dimensions.width, dimensions.height,
                           format.videoSupportedFrameRateRanges.firstObject.maxFrameRate);
                }
                
                break;
            }
        }
    }
    
    // Adaptar o WebRTCManager para a câmera atual
    [self.webRTCManager adaptToNativeCameraWithPosition:self.currentCameraPosition];
    
    self.configured = YES;
    writeLog(@"[WebRTCBufferInjector] Configurado com sucesso para sessão");
}

- (void)updateCameraInfo:(AVCaptureSession *)session {
    // Detectar posição da câmera atual
    AVCaptureDevicePosition oldPosition = self.currentCameraPosition;
    
    for (AVCaptureDeviceInput *input in session.inputs) {
        if ([input.device hasMediaType:AVMediaTypeVideo]) {
            self.currentCameraPosition = input.device.position;
            
            // Log detalhado sobre o dispositivo de câmera
            writeLog(@"[WebRTCBufferInjector] Câmera detectada: %@ (posição: %@, ID: %@)",
                   input.device.localizedName,
                   self.currentCameraPosition == AVCaptureDevicePositionBack ? @"traseira" :
                   (self.currentCameraPosition == AVCaptureDevicePositionFront ? @"frontal" : @"desconhecida"),
                   input.device.uniqueID);
            
            // Se a sessão estiver configurada para formato específico, tentar detectá-lo
            if ([input.device respondsToSelector:@selector(activeFormat)]) {
                AVCaptureDeviceFormat *format = input.device.activeFormat;
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                
                writeLog(@"[WebRTCBufferInjector] Formato ativo: %dx%d, %@ fps",
                       dimensions.width, dimensions.height,
                       format.videoSupportedFrameRateRanges.firstObject.maxFrameRate);
            }
            
            break;
        }
    }
    
    // Se a posição mudou, atualizar o WebRTCManager
    if (oldPosition != self.currentCameraPosition) {
        [self.webRTCManager adaptToNativeCameraWithPosition:self.currentCameraPosition];
    }
}

- (void)activateInjection {
    if (_active) {
        writeLog(@"[WebRTCBufferInjector] Injeção já está ativa, ignorando chamada duplicada");
        return;
    }
    
    writeLog(@"[WebRTCBufferInjector] Ativando injeção de buffer");
    _active = YES;
    
    // Verificar se o WebRTCManager está recebendo frames
    if (self.webRTCManager && !self.webRTCManager.isReceivingFrames) {
        // Iniciar conexão WebRTC se necessário
        [self.webRTCManager startWebRTC];
        
        // Aguardar para garantir que o WebRTC esteja pronto
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            [self configurarMonitoramentoNaoIntrusivo];
        });
    } else {
        // WebRTC já está recebendo frames, ativar imediatamente
        [self configurarMonitoramentoNaoIntrusivo];
    }
}

- (void)configurarMonitoramentoNaoIntrusivo {
    if (!self.captureSession || !self.active) {
        writeLog(@"[WebRTCBufferInjector] Sessão não disponível ou injeção não ativa");
        return;
    }
    
    // Verificar se podemos modificar a sessão (ela deve estar em execução)
    if (self.captureSession.isRunning) {
        writeLog(@"[WebRTCBufferInjector] Adicionando output de monitoramento não-intrusivo");
        
        // Primeiro, verificar se já temos nossa saída na sessão
        BOOL outputExists = NO;
        for (AVCaptureOutput *output in self.captureSession.outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]] &&
                ((AVCaptureVideoDataOutput *)output).sampleBufferDelegate == self) {
                outputExists = YES;
                break;
            }
        }
        
        if (!outputExists) {
            // Criar e configurar nossa própria saída
            AVCaptureVideoDataOutput *dataOutput = [[AVCaptureVideoDataOutput alloc] init];
            dataOutput.alwaysDiscardsLateVideoFrames = YES;
            
            // Corresponder ao formato detectado da câmera
            NSNumber *formatType = @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange); // 420f
            dataOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: formatType};
            
            // Criar uma fila dedicada para nossos frames
            dispatch_queue_t videoQueue = dispatch_queue_create("com.webrtc.videoqueue", DISPATCH_QUEUE_SERIAL);
            
            // Configurar nós mesmos como delegado em nossa própria fila
            [dataOutput setSampleBufferDelegate:self queue:videoQueue];
            
            // Tentar adicionar a saída à sessão
            if ([self.captureSession canAddOutput:dataOutput]) {
                [self.captureSession addOutput:dataOutput];
                writeLog(@"[WebRTCBufferInjector] Output de monitoramento adicionado com sucesso");
            } else {
                writeLog(@"[WebRTCBufferInjector] Não foi possível adicionar output de monitoramento");
            }
        } else {
            writeLog(@"[WebRTCBufferInjector] Output de monitoramento já existe");
        }
    } else {
        writeLog(@"[WebRTCBufferInjector] Sessão não está ativa, não podemos modificar");
    }
}

- (void)activateInjectionForOutputs {
    // Só prosseguir se ainda estiver ativo (pode ter sido desativado enquanto esperávamos)
    if (!_active) return;
    
    // Procurar todas as saídas de vídeo para substituir delegates
    if (self.captureSession) {
        BOOL delegateFound = NO;
        
        for (AVCaptureOutput *output in self.captureSession.outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                AVCaptureVideoDataOutput *videoOutput = (AVCaptureVideoDataOutput *)output;
                
                // Armazenar delegate original para referência, se ainda não tiver sido armazenado
                id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate = videoOutput.sampleBufferDelegate;
                dispatch_queue_t originalQueue = videoOutput.sampleBufferCallbackQueue;
                
                if (originalDelegate && originalDelegate != self) {
                    [self registerOriginalDelegate:originalDelegate queue:originalQueue];
                    
                    // Substituir o delegate pelo injector
                    [videoOutput setSampleBufferDelegate:self queue:originalQueue];
                    
                    writeLog(@"[WebRTCBufferInjector] Delegate substituído para saída de vídeo");
                    delegateFound = YES;
                }
            }
        }
        
        if (!delegateFound) {
            writeWarningLog(@"[WebRTCBufferInjector] Nenhum delegate de saída de vídeo encontrado para substituir");
        }
    }
}

- (void)deactivateInjection {
    if (!_active) return;
    
    writeLog(@"[WebRTCBufferInjector] Desativando injeção de buffer");
    _active = NO;
    
    // Remover nosso output da sessão se possível
    if (self.captureSession && self.captureSession.isRunning) {
        for (AVCaptureOutput *output in self.captureSession.outputs) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]] &&
                ((AVCaptureVideoDataOutput *)output).sampleBufferDelegate == self) {
                [self.captureSession removeOutput:output];
                writeLog(@"[WebRTCBufferInjector] Output de monitoramento removido");
                break;
            }
        }
    }
}

- (void)registerOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!delegate) {
        writeLog(@"[WebRTCBufferInjector] Tentativa de registrar delegate nulo");
        return;
    }
    
    // Armazenar o delegate original e sua queue para encaminhamento
    NSString *key = [NSString stringWithFormat:@"%p", delegate];
    
    // Verificar se este delegate já está registrado
    if (self.originalDelegates[key]) {
        writeLog(@"[WebRTCBufferInjector] Delegate %@ já registrado, atualizando queue",
               NSStringFromClass([delegate class]));
    }
    
    self.originalDelegates[key] = @{
        @"delegate": delegate,
        @"queue": queue ?: dispatch_get_main_queue()
    };
    
    writeLog(@"[WebRTCBufferInjector] Delegate registrado: %@ com key %@",
           NSStringFromClass([delegate class]), key);
    
    // Verificar se o delegate implementa os métodos necessários
    BOOL hasOutputMethod = [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)];
    BOOL hasDropMethod = [delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)];
    
    writeLog(@"[WebRTCBufferInjector] Delegate implementa didOutputSampleBuffer: %@, didDropSampleBuffer: %@",
           hasOutputMethod ? @"Sim" : @"Não",
           hasDropMethod ? @"Sim" : @"Não");
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    // Incrementar contador de frames
    self.frameCount++;
    
    // Log periódico
    BOOL isLogFrame = (self.frameCount % 60 == 0);
    
    if (isLogFrame) {
        writeLog(@"[WebRTCBufferInjector] Processando frame #%d, substituição ativa: %@",
               (int)self.frameCount, self.active ? @"SIM" : @"NÃO");
    }
    
    // Verificar se a substituição está ativa
    if (!self.active || !self.webRTCManager || !originalBuffer || !CMSampleBufferIsValid(originalBuffer)) {
        // Modo observacional: apenas monitorar os frames originais
        return;
    }
    
    // Extrair informações do buffer original
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(originalBuffer);
    if (!formatDescription) return;
    
    // Extrair dimensões e formato
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
    
    if (isLogFrame) {
        writeLog(@"[WebRTCBufferInjector] Frame original #%d - Dimensões: %dx%d, Formato: %d",
               (int)self.frameCount, dimensions.width, dimensions.height, (int)pixelFormat);
    }
    
    // Adaptar o WebRTCManager para coincidir com a câmera nativa
    [self.webRTCManager setTargetResolution:dimensions];
    
    // Verificar orientação da conexão
    if ([connection respondsToSelector:@selector(isVideoOrientationSupported)] &&
        [connection isVideoOrientationSupported]) {
        AVCaptureVideoOrientation orientation = connection.videoOrientation;
        [self.webRTCManager adaptOutputToVideoOrientation:(int)orientation];
    }
    
    // Verificar espelhamento
    if ([connection respondsToSelector:@selector(isVideoMirrored)]) {
        BOOL mirrored = connection.isVideoMirrored;
        [self.webRTCManager setVideoMirrored:mirrored];
    }
    
    // Fase 1: Modo Observacional (Initial Learning)
    // Apenas processar os frames para aprendizado e análise
    
    // Opcional: Se estamos em modo de visualização (floating window), processar frame para UI
    if (self.webRTCManager.floatingWindow) {
        // Converter o formato para string legível
        char formatChars[5] = {0};
        formatChars[0] = (pixelFormat >> 24) & 0xFF;
        formatChars[1] = (pixelFormat >> 16) & 0xFF;
        formatChars[2] = (pixelFormat >> 8) & 0xFF;
        formatChars[3] = pixelFormat & 0xFF;
        formatChars[4] = 0;
        
        NSString *formatString = [NSString stringWithUTF8String:formatChars];
        
        // Atualizar informações na floating window
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *infoText = [NSString stringWithFormat:@"%dx%d (%@)",
                               dimensions.width, dimensions.height, formatString];
            
            // Verificar se os métodos existem antes de chamar
            if ([self.webRTCManager.floatingWindow respondsToSelector:@selector(updateFormatInfo:)]) {
                [self.webRTCManager.floatingWindow performSelector:@selector(updateFormatInfo:) withObject:infoText];
            }
            
            // Atualizar label de processamento
            NSString *processingInfo = @"Monitorando frames nativos";
            if ([self.webRTCManager.floatingWindow respondsToSelector:@selector(updateProcessingMode:)]) {
                [self.webRTCManager.floatingWindow performSelector:@selector(updateProcessingMode:) withObject:processingInfo];
            }
        });
    }

    // Fase 2: Quando estiver pronto para fase de substituição real:
    // Este bloco seria ativado quando uma flag de "substituiçãoCompleta" estiver habilitada
    if (NO) { // Desativado por enquanto - será ativado em versões futuras
        // Obter buffer WebRTC adaptado
        CMSampleBufferRef webRTCBuffer = [self.webRTCManager getLatestVideoSampleBufferWithOriginalMetadata:originalBuffer];
        
        if (webRTCBuffer && CMSampleBufferIsValid(webRTCBuffer)) {
            // Verificar compatibilidade
            if ([self isBufferCompatible:webRTCBuffer withOriginal:originalBuffer]) {
                // Usar o WebRTCBuffer para substituir o original
                // Implementação futura
                
                // Incrementar contador de frames substituídos
                self.replacedFrameCount++;
            }
            
            // Liberar o buffer WebRTC após uso
            CFRelease(webRTCBuffer);
        }
    }
    
    // Registrar estatísticas de frame para análise
    if (isLogFrame) {
        writeLog(@"[WebRTCBufferInjector] Estatísticas: %d frames processados, %d substituídos",
               (int)self.frameCount, (int)self.replacedFrameCount);
    }
}

// Método auxiliar para converter formato OSType para string legível
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

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // Encaminhar evento de buffer descartado para todos os delegates
    for (NSString *key in self.originalDelegates) {
        NSDictionary *delegateInfo = self.originalDelegates[key];
        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = delegateInfo[@"delegate"];
        dispatch_queue_t queue = delegateInfo[@"queue"];
        
        if (delegate && [delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
            dispatch_async(queue, ^{
                @try {
                    [delegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCBufferInjector] Erro ao encaminhar evento de buffer descartado: %@", exception);
                }
            });
        }
    }
}

- (void)forwardBuffer:(CMSampleBufferRef)buffer toOutput:(AVCaptureOutput *)output connection:(AVCaptureConnection *)connection {
    if (!buffer || self.originalDelegates.count == 0) {
        return;
    }
    
    // Encaminhar o buffer para todos os delegates registrados
    for (NSString *key in self.originalDelegates) {
        NSDictionary *delegateInfo = self.originalDelegates[key];
        id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = delegateInfo[@"delegate"];
        dispatch_queue_t queue = delegateInfo[@"queue"];
        
        if (delegate && [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            dispatch_async(queue, ^{
                @try {
                    [delegate captureOutput:output didOutputSampleBuffer:buffer fromConnection:connection];
                } @catch (NSException *exception) {
                    writeLog(@"[WebRTCBufferInjector] Erro ao encaminhar buffer: %@", exception);
                }
            });
        }
    }
}

- (void)forwardOriginalBuffer:(CMSampleBufferRef)buffer toOutput:(AVCaptureOutput *)output connection:(AVCaptureConnection *)connection {
    // Encaminhar o buffer original (sem substituição) para todos os delegates
    [self forwardBuffer:buffer toOutput:output connection:connection];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    
    if (active) {
        [self activateInjection];
    } else {
        [self deactivateInjection];
    }
}

#pragma mark - Helper Methods

- (BOOL)applyMetadataFromBuffer:(CMSampleBufferRef)originalBuffer toBuffer:(CMSampleBufferRef)webRTCBuffer {
    if (!originalBuffer || !webRTCBuffer) return NO;
    
    BOOL success = YES;
    
    @try {
        // 1. Copiar attachments do buffer original
        CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(originalBuffer, false);
        if (attachmentsArray && CFArrayGetCount(attachmentsArray) > 0) {
            CFDictionaryRef originalAttachments = (CFDictionaryRef)CFArrayGetValueAtIndex(attachmentsArray, 0);
            
            // Obter attachments do buffer WebRTC
            CFArrayRef webRTCAttachmentsArray = CMSampleBufferGetSampleAttachmentsArray(webRTCBuffer, true);
            if (webRTCAttachmentsArray && CFArrayGetCount(webRTCAttachmentsArray) > 0) {
                CFMutableDictionaryRef webRTCAttachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(webRTCAttachmentsArray, 0);
                
                // Copiar chaves específicas
                const void *keys[] = {
                    kCMSampleAttachmentKey_DisplayImmediately,
                    kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                    kCMSampleBufferAttachmentKey_DroppedFrameReason,
                    kCMSampleAttachmentKey_NotSync
                };
                
                for (int i = 0; i < 4; i++) {
                    const void *value = CFDictionaryGetValue(originalAttachments, keys[i]);
                    if (value) {
                        CFDictionarySetValue(webRTCAttachments, keys[i], value);
                    }
                }
            }
        }
        
        // 2. Copiar metadados específicos da câmera (como informações de exposição)
        CFDictionaryRef originalMetadata = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                       originalBuffer,
                                                                       kCMAttachmentMode_ShouldPropagate);
        if (originalMetadata) {
            // Anexar metadados ao buffer WebRTC
            CMSetAttachments(webRTCBuffer, originalMetadata, kCMAttachmentMode_ShouldPropagate);
            CFRelease(originalMetadata);
        }
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCBufferInjector] Erro ao aplicar metadados: %@", exception);
        success = NO;
    }
    
    return success;
}

// Método melhorado para verificar compatibilidade de buffers com logs detalhados
- (BOOL)isBufferCompatible:(CMSampleBufferRef)webRTCBuffer withOriginal:(CMSampleBufferRef)originalBuffer {
    if (!webRTCBuffer || !originalBuffer) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Um ou ambos os buffers são NULL");
        return NO;
    }
    
    // Verificar validade dos buffers
    if (!CMSampleBufferIsValid(webRTCBuffer) || !CMSampleBufferIsValid(originalBuffer)) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Um ou ambos os buffers são inválidos");
        return NO;
    }
    
    // Obter descrições de formato com verificações de segurança
    CMFormatDescriptionRef originalFormat = CMSampleBufferGetFormatDescription(originalBuffer);
    CMFormatDescriptionRef webRTCFormat = CMSampleBufferGetFormatDescription(webRTCBuffer);
    
    if (!originalFormat || !webRTCFormat) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Descrição de formato não disponível");
        return NO;
    }
    
    // Verificar tipo de mídia (deve ser vídeo para ambos)
    CMMediaType originalMediaType = CMFormatDescriptionGetMediaType(originalFormat);
    CMMediaType webRTCMediaType = CMFormatDescriptionGetMediaType(webRTCFormat);
    
    if (originalMediaType != webRTCMediaType || originalMediaType != kCMMediaType_Video) {
        writeErrorLog(@"[WebRTCBufferInjector] isBufferCompatible: Tipos de mídia incompatíveis: original=%d, webRTC=%d",
                     (int)originalMediaType, (int)webRTCMediaType);
        return NO;
    }
    
    // Obter dimensões dos buffers
    CMVideoDimensions originalDims = CMVideoFormatDescriptionGetDimensions(originalFormat);
    CMVideoDimensions webRTCDims = CMVideoFormatDescriptionGetDimensions(webRTCFormat);
    
    // Obter formatos de pixel
    OSType originalPixelFormat = CMFormatDescriptionGetMediaSubType(originalFormat);
    OSType webRTCPixelFormat = CMFormatDescriptionGetMediaSubType(webRTCFormat);
    
    // Log detalhado para diagnóstico ocasional (não em cada frame)
    static int logCounter = 0;
    if (++logCounter % 100 == 0) {
        writeLog(@"[WebRTCBufferInjector] Verificando compatibilidade - Original: %dx%d (%d), WebRTC: %dx%d (%d)",
               originalDims.width, originalDims.height, (int)originalPixelFormat,
               webRTCDims.width, webRTCDims.height, (int)webRTCPixelFormat);
    }
    
    // Permitir tolerância de 10% nas dimensões
    float widthRatio = (float)webRTCDims.width / originalDims.width;
    float heightRatio = (float)webRTCDims.height / originalDims.height;
    
    if (widthRatio < 0.9 || widthRatio > 1.1 || heightRatio < 0.9 || heightRatio > 1.1) {
        // Log apenas ocasionalmente para evitar spam
        if (logCounter % 100 == 0) {
            writeLog(@"[WebRTCBufferInjector] Dimensões incompatíveis - Original: %dx%d, WebRTC: %dx%d",
                   originalDims.width, originalDims.height, webRTCDims.width, webRTCDims.height);
        }
        return NO;
    }
    
    // Verificar formatos de pixel - comentado para maior flexibilidade
    // Se descomentar isso, será mais estrito na compatibilidade de formatos
    /*
    if (originalPixelFormat != webRTCPixelFormat) {
        // Permitir algumas substituições comuns entre formatos compatíveis
        BOOL isCompatibleFormat =
            // Permitir substituição entre formatos YUV
            ((originalPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              originalPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) &&
             (webRTCPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              webRTCPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) ||
            // Permitir substituição entre formatos RGBA/BGRA
            ((originalPixelFormat == kCVPixelFormatType_32BGRA ||
              originalPixelFormat == kCVPixelFormatType_32RGBA) &&
             (webRTCPixelFormat == kCVPixelFormatType_32BGRA ||
              webRTCPixelFormat == kCVPixelFormatType_32RGBA));
        
        if (!isCompatibleFormat) {
            if (logCounter % 100 == 0) {
                writeLog(@"[WebRTCBufferInjector] Formatos de pixel incompatíveis - Original: %d, WebRTC: %d",
                        (int)originalPixelFormat, (int)webRTCPixelFormat);
            }
            return NO;
        }
    }
    */
    
    // Verificar timing info (opcional)
    /*
    CMSampleTimingInfo originalTiming;
    CMSampleTimingInfo webRTCTiming;
    
    if (CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &originalTiming) == noErr &&
        CMSampleBufferGetSampleTimingInfo(webRTCBuffer, 0, &webRTCTiming) == noErr) {
        
        // Verificar duração dos frames (tolerância de 20%)
        float durationRatio = CMTimeGetSeconds(webRTCTiming.duration) / CMTimeGetSeconds(originalTiming.duration);
        if (durationRatio < 0.8 || durationRatio > 1.2) {
            if (logCounter % 100 == 0) {
                writeLog(@"[WebRTCBufferInjector] Durações de frame incompatíveis - Original: %.3fs, WebRTC: %.3fs",
                        CMTimeGetSeconds(originalTiming.duration), CMTimeGetSeconds(webRTCTiming.duration));
            }
            // Comentado para não falhar por timing
            // return NO;
        }
    }
    */
    
    return YES;
}

- (NSDictionary *)getInjectionStats {
    return @{
        @"framesProcessed": @(self.frameCount),
        @"framesReplaced": @(self.replacedFrameCount),
        @"replacementRate": self.frameCount > 0 ? @((float)self.replacedFrameCount / self.frameCount) : @(0),
        @"isActive": @(self.active),
        @"isConfigured": @(self.configured),
        @"delegatesRegistered": @(self.originalDelegates.count),
        @"cameraPosition": @(self.currentCameraPosition)
    };
}

@end
