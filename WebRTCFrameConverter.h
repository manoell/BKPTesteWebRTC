#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

/**
 * Enum para formatos de pixel nativos do iOS
 */
typedef NS_ENUM(NSInteger, IOSPixelFormat) {
    IOSPixelFormatUnknown = 0,
    IOSPixelFormat420f,   // YUV 4:2:0 full-range (formato preferido do iOS)
    IOSPixelFormat420v,   // YUV 4:2:0 video-range
    IOSPixelFormatBGRA    // 32-bit BGRA
};

/**
 * WebRTCFrameConverter
 *
 * Classe responsável por converter frames WebRTC em formatos utilizáveis por UIKit (UIImage)
 * e AVFoundation (CMSampleBuffer). Otimizada para alta resolução (1080p+) e formatos nativos iOS.
 */
@interface WebRTCFrameConverter : NSObject <RTCVideoRenderer>

/**
 * Callback chamado quando um novo frame está disponível.
 * @param image UIImage convertida do frame WebRTC.
 */
@property (nonatomic, copy) void (^frameCallback)(UIImage *image);

/**
 * Indica se o converter está recebendo frames ativamente.
 */
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

/**
 * Contador de frames recebidos.
 */
@property (nonatomic, assign, readonly) int frameCount;

/**
 * Formato atual de pixel detectado dos frames recebidos
 */
@property (nonatomic, assign, readonly) IOSPixelFormat detectedPixelFormat;

/**
 * Forma como os frames estão sendo processados (hardware/software)
 */
@property (nonatomic, copy, readonly) NSString *processingMode;

@property (nonatomic, assign, readonly) NSUInteger totalSampleBuffersCreated;
@property (nonatomic, assign, readonly) NSUInteger totalSampleBuffersReleased;
@property (nonatomic, assign) NSUInteger totalPixelBuffersLocked;
@property (nonatomic, assign) NSUInteger totalPixelBuffersUnlocked;

/**
 * Dicionário para rastreamento ativo de sample buffers
 */
@property (nonatomic, strong, readonly) NSMutableDictionary *activeSampleBuffers;

/**
 * Dicionário para timestamps de cache
 */
@property (nonatomic, strong, readonly) NSMutableDictionary *sampleBufferCacheTimestamps;

/**
 * Timer para monitoramento de recursos
 */
@property (nonatomic, strong) dispatch_source_t resourceMonitorTimer;

/**
 * Incrementa o contador de bloqueios de PixelBuffer
 */
- (void)incrementPixelBufferLockCount;

/**
 * Incrementa o contador de desbloqueios de PixelBuffer
 */
- (void)incrementPixelBufferUnlockCount;

/**
 * Força a liberação de todos os sample buffers ativos
 */
- (void)forceReleaseAllSampleBuffers;

/**
 * Inicializa o conversor de frames.
 * @return Uma nova instância do conversor.
 */
- (instancetype)init;

/**
 * Define manualmente um frame para renderização.
 * @param frame O frame WebRTC a ser renderizado.
 */
- (void)setRenderFrame:(RTCVideoFrame *)frame;

/**
 * Obtém o buffer de amostra mais recente, adequado para injeção em AVCaptureSession.
 * @param pixelFormat Formato de pixel desejado para o buffer de saída
 * @return CMSampleBufferRef contendo o frame atual, ou NULL se não disponível.
 */
- (CMSampleBufferRef)getLatestSampleBufferWithFormat:(IOSPixelFormat)pixelFormat;

/**
 * Obtém o buffer de amostra mais recente usando o formato nativo detectado.
 * @return CMSampleBufferRef contendo o frame atual, ou NULL se não disponível.
 */
- (CMSampleBufferRef)getLatestSampleBuffer;

/**
 * Cria um CMSampleBuffer a partir do último frame com formatação específica.
 * @param format Formato de pixel desejado (kCVPixelFormatType_*)
 * @return CMSampleBufferRef formatado, ou NULL em caso de erro
 */
- (CMSampleBufferRef)createSampleBufferWithFormat:(OSType)format;

/**
 * Obtém o último frame como UIImage.
 * @return UIImage do último frame recebido, ou nil se não disponível.
 */
- (UIImage *)getLastFrameAsImage;

/**
 * Obtém estatísticas de processamento de frame.
 * @return NSDictionary contendo estatísticas como tempo médio de processamento e FPS.
 */
- (NSDictionary *)getFrameProcessingStats;

/**
 * Define a resolução alvo para adaptação.
 * @param resolution A resolução de destino para adaptar os frames.
 */
- (void)setTargetResolution:(CMVideoDimensions)resolution;

/**
 * Define a taxa de quadros alvo para adaptação.
 * @param frameRate Taxa de quadros desejada em fps.
 */
- (void)setTargetFrameRate:(float)frameRate;

/**
 * Adapta-se ao formato específico da câmera atual do iOS.
 * @param format Formato de pixel nativo (como kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
 * @param resolution Resolução da câmera
 */
- (void)adaptToNativeCameraFormat:(OSType)format resolution:(CMVideoDimensions)resolution;

/**
 * Converte um formato OSType de CoreVideo para formato IOSPixelFormat.
 * @param cvFormat Formato OSType de CoreVideo (como kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
 * @return IOSPixelFormat correspondente
 */
+ (IOSPixelFormat)pixelFormatFromCVFormat:(OSType)cvFormat;

/**
 * Converte um IOSPixelFormat para OSType de CoreVideo.
 * @param iosFormat Formato IOSPixelFormat
 * @return OSType de CoreVideo correspondente
 */
+ (OSType)cvFormatFromPixelFormat:(IOSPixelFormat)iosFormat;

/**
 * Retorna uma string descritiva para o formato de pixel.
 * @param format Formato IOSPixelFormat
 * @return String descritiva do formato
 */
+ (NSString *)stringFromPixelFormat:(IOSPixelFormat)format;

/**
 * Reset o conversor para um estado limpo.
 * Limpa o cache interno e reinicia contadores.
 */
- (void)reset;

/**
 * Realiza uma limpeza segura de todos os recursos.
 * Este método deve ser chamado quando o app entra em background ou em situações de baixa memória.
 */
- (void)performSafeCleanup;

/**
 * Libera explicitamente um CMSampleBuffer e atualiza contadores.
 * @param buffer O buffer a ser liberado.
 */
- (void)releaseSampleBuffer:(CMSampleBufferRef)buffer;

/**
 * Monitora e corrige automaticamente vazamentos de recursos.
 */
- (void)checkForResourceLeaks;

/**
 * Inicia o monitoramento periódico de recursos.
 */
- (void)startResourceMonitoring;

/**
 * Otimiza o sistema de cache removendo entradas antigas.
 */
- (void)optimizeCacheSystem;

/**
 * Limpa o cache de sample buffers atual.
 */
- (void)clearSampleBufferCache;

/**
 * Relógio da sessão de captura para sincronização precisa
 * (NULL se não estiver em modo de substituição de câmera)
 */
@property (nonatomic, assign) CMClockRef captureSessionClock;

/**
 * Timestamp do último frame processado, usado para timing
 */
@property (nonatomic, assign) CMTime lastProcessedFrameTimestamp;

/**
 * Timestamp do último buffer criado
 */
@property (nonatomic, assign) CMTime lastBufferTimestamp;

/**
 * Contador de frames descartados pelo mecanismo de adaptação
 */
@property (nonatomic, assign) NSUInteger droppedFrameCount;

/**
 * Taxa de frames atual calculada
 */
@property (nonatomic, assign) float currentFps;

// Adicionar estes métodos à interface WebRTCFrameConverter em WebRTCFrameConverter.h

/**
 * Verifica se um frame deve ser descartado com base na cadência e timing
 * @param frameTimestamp Timestamp do frame a verificar
 * @return TRUE se o frame deve ser descartado, FALSE caso contrário
 */
- (BOOL)shouldDropFrameWithTimestamp:(CMTime)frameTimestamp;

/**
 * Adiciona timestamps e attachment de timing à um sample buffer existente
 * @param sampleBuffer Sample buffer original
 * @param preserveOriginalTiming Se TRUE, tenta preservar o timing original
 * @return CMSampleBufferRef com timing atualizado ou NULL em caso de erro
 */
- (CMSampleBufferRef)enhanceSampleBufferTiming:(CMSampleBufferRef)sampleBuffer
                         preserveOriginalTiming:(BOOL)preserveOriginalTiming;

/**
 * Obtém o CMClockRef mais adequado para sincronização
 * @return O CMClockRef a ser usado para sincronização
 */
- (CMClockRef)getCurrentSyncClock;

/**
 * Define o relógio de sincronização da AVCaptureSession para substituição
 * @param clock CMClockRef da sessão de captura
 */
- (void)setCaptureSessionClock:(CMClockRef)clock;

/**
 * Obtém metadados de um buffer de amostra original para preservação
 * @param originalBuffer O buffer original da câmera
 * @return Dicionário com metadados extraídos ou nil se não disponível
 */
- (NSDictionary *)extractMetadataFromSampleBuffer:(CMSampleBufferRef)originalBuffer;

/**
 * Aplica metadados previamente extraídos a um sample buffer
 * @param sampleBuffer O buffer onde aplicar os metadados
 * @param metadata Dicionário com metadados a aplicar
 * @return TRUE se sucesso, FALSE caso contrário
 */
- (BOOL)applyMetadataToSampleBuffer:(CMSampleBufferRef)sampleBuffer metadata:(NSDictionary *)metadata;

/**
 * Converte um buffer YUV para RGB usando aceleração de hardware quando disponível.
 * @param pixelBuffer Buffer YUV de entrada (420f ou 420v)
 * @return Buffer RGB otimizado ou NULL em caso de erro
 */
- (CVPixelBufferRef)convertYUVToRGBWithHardwareAcceleration:(CVPixelBufferRef)pixelBuffer;

/**
 * Verifica se a aceleração de hardware está disponível para conversão de formato.
 * @return TRUE se aceleração de hardware está disponível, FALSE caso contrário
 */
- (BOOL)isHardwareAccelerationAvailable;

/**
 * Configura e mantém um contexto de conversão colorSyncTransform para otimizar conversões repetidas.
 * @param sourceFormat Formato OSType de origem (ex: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
 * @param destFormat Formato OSType de destino (ex: kCVPixelFormatType_32BGRA)
 * @return TRUE se o contexto foi criado com sucesso
 */
- (BOOL)setupColorConversionContextFromFormat:(OSType)sourceFormat toFormat:(OSType)destFormat;

/**
 * Detecta e configura aceleração de hardware disponível no dispositivo.
 * @return TRUE se aceleração de hardware foi configurada com sucesso
 */
- (BOOL)configureHardwareAcceleration;

/**
 * Otimiza uso de memória para o processamento de vídeo.
 * @param optimize Se TRUE, otimiza para performance em detrimento da memória
 */
- (void)optimizeForPerformance:(BOOL)optimize;

/**
 * Escalona um buffer de pixels para a resolução alvo com otimização de hardware.
 * @param pixelBuffer Buffer original a ser escalonado
 * @return Novo buffer na resolução alvo ou NULL em caso de erro
 */
- (RTCCVPixelBuffer *)scalePixelBufferToTargetSize:(RTCCVPixelBuffer *)pixelBuffer;

/**
 * Controla a adaptação de taxa de frames para melhorar performance.
 * @param newStrategy Estratégia de adaptação ("quality", "balanced", "performance")
 */
- (void)setFrameRateAdaptationStrategy:(NSString *)newStrategy;

/**
 * Determina se um frame deve ser processado com base em heurísticas de carga
 * @param frame Frame a ser verificado
 * @return TRUE se o frame deve ser processado, FALSE para descartar
 */
- (BOOL)shouldProcessFrame:(RTCVideoFrame *)frame;

/**
 * Define se a saída deve ser espelhada.
 * @param mirror TRUE para espelhar a saída, FALSE caso contrário.
 */
- (void)setMirrorOutput:(BOOL)mirror;

@end
