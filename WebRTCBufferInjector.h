#ifndef WEBRTCBUFFERINJECTOR_H
#define WEBRTCBUFFERINJECTOR_H

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "WebRTCManager.h"
#import "WebRTCFrameConverter.h"

/**
 * WebRTCBufferInjector
 *
 * Classe singleton responsável por interceptar o feed da câmera nativa
 * e substituí-lo pelo stream WebRTC em tempo real.
 * Implementa o padrão delegate para AVCaptureVideoDataOutput para
 * interceptar frames da câmera e injetar frames WebRTC.
 */
@interface WebRTCBufferInjector : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

/**
 * Flag que indica se a injeção está ativa.
 */
@property (nonatomic, assign, getter=isActive) BOOL active;

/**
 * Flag que indica se o buffer injector está configurado.
 */
@property (nonatomic, assign, getter=isConfigured) BOOL configured;

/**
 * WebRTCManager compartilhado.
 */
@property (nonatomic, strong) WebRTCManager *webRTCManager;

/**
 * WebRTCFrameConverter compartilhado.
 */
@property (nonatomic, strong) WebRTCFrameConverter *frameConverter;

/**
 * Posição atual da câmera (frontal/traseira).
 */
@property (nonatomic, assign) AVCaptureDevicePosition currentCameraPosition;

/**
 * Dicionário para armazenar delegates originais e suas filas.
 */
@property (nonatomic, strong) NSMutableDictionary *originalDelegates;

/**
 * Sessão de captura que está sendo interceptada
 */
@property (nonatomic, weak) AVCaptureSession *captureSession;

/**
 * Contador de frames processados
 */
@property (nonatomic, assign) NSUInteger frameCount;

/**
 * Contador de frames substituídos
 */
@property (nonatomic, assign) NSUInteger replacedFrameCount;

/**
 * Obtém a instância compartilhada (singleton).
 */
+ (instancetype)sharedInstance;

/**
 * Configura o injetor com uma sessão de captura.
 * @param session A sessão AVCaptureSession para interceptar.
 */
- (void)configureWithSession:(AVCaptureSession *)session;

/**
 * Ativa a injeção de buffer WebRTC.
 */
- (void)activateInjection;

/**
 * Desativa a injeção de buffer WebRTC.
 */
- (void)deactivateInjection;

/**
 * Registra um delegate original e sua fila associada.
 * @param delegate O delegate original de AVCaptureVideoDataOutput.
 * @param queue A fila de dispatch associada ao delegate.
 */
- (void)registerOriginalDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue;

/**
 * Encaminha um buffer de amostra para os delegates registrados.
 * @param buffer O buffer de amostra a ser encaminhado.
 * @param output O AVCaptureOutput de origem.
 * @param connection A conexão de origem.
 */
- (void)forwardBuffer:(CMSampleBufferRef)buffer toOutput:(AVCaptureOutput *)output connection:(AVCaptureConnection *)connection;

/**
 * Encaminha o buffer original (sem substituição) para os delegates.
 * @param buffer O buffer de amostra original.
 * @param output O AVCaptureOutput de origem.
 * @param connection A conexão de origem.
 */
- (void)forwardOriginalBuffer:(CMSampleBufferRef)buffer toOutput:(AVCaptureOutput *)output connection:(AVCaptureConnection *)connection;

/**
 * Aplica metadados do buffer original para o buffer WebRTC para compatibilidade.
 * @param originalBuffer O buffer original da câmera.
 * @param webRTCBuffer O buffer WebRTC que receberá os metadados.
 * @return TRUE se bem-sucedido, FALSE em caso de erro.
 */
- (BOOL)applyMetadataFromBuffer:(CMSampleBufferRef)originalBuffer toBuffer:(CMSampleBufferRef)webRTCBuffer;

/**
 * Atualiza informações sobre a sessão de câmera atual.
 * @param session A sessão AVCaptureSession.
 */
- (void)updateCameraInfo:(AVCaptureSession *)session;

/**
 * Verifica se um buffer WebRTC é compatível com o buffer original da câmera.
 * @param webRTCBuffer O buffer WebRTC a ser verificado.
 * @param originalBuffer O buffer original da câmera para comparação.
 * @return TRUE se compatível, FALSE caso contrário.
 */
- (BOOL)isBufferCompatible:(CMSampleBufferRef)webRTCBuffer withOriginal:(CMSampleBufferRef)originalBuffer;

/**
 * Obtém estatísticas sobre a substituição de buffer.
 * @return Dicionário com estatísticas como contadores de frames e taxa de substituição.
 */
- (NSDictionary *)getInjectionStats;

@end

#endif /* WEBRTCBUFFERINJECTOR_H */
