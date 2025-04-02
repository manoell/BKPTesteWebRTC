#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>
#import "WebRTCFrameConverter.h"

@class FloatingWindow;

/**
 * Estado de conexão do WebRTCManager
 */
typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,    // Desconectado do servidor WebRTC
    WebRTCManagerStateConnecting,      // Tentando conectar ao servidor WebRTC
    WebRTCManagerStateConnected,       // Conectado e pronto para receber frames
    WebRTCManagerStateError,           // Erro na conexão WebRTC
    WebRTCManagerStateReconnecting     // Reconectando após falha
};

/**
 * Configuração de adaptação para diferentes formatos de câmera
 */
typedef NS_ENUM(NSInteger, WebRTCAdaptationMode) {
    WebRTCAdaptationModeAuto,          // Detectar e adaptar automaticamente
    WebRTCAdaptationModePerformance,   // Priorizar desempenho
    WebRTCAdaptationModeQuality,       // Priorizar qualidade
    WebRTCAdaptationModeCompatibility  // Priorizar compatibilidade com iOS
};

/**
 * WebRTCManager
 *
 * Classe responsável pelo gerenciamento da conexão WebRTC.
 * Otimizada para suportar formatos nativos de câmera do iOS.
 */
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

/**
 * Referência à janela flutuante para atualização de UI
 */
@property (nonatomic, weak) FloatingWindow *floatingWindow;

/**
 * Estado atual da conexão WebRTC
 */
@property (nonatomic, assign, readonly) WebRTCManagerState state;

/**
 * Endereço IP do servidor
 */
@property (nonatomic, strong) NSString *serverIP;

/**
 * Conversor de frames WebRTC para processamento eficiente de vídeo
 */
@property (nonatomic, strong, readonly) WebRTCFrameConverter *frameConverter;

/**
 * Modo de adaptação para câmera atual
 */
@property (nonatomic, assign) WebRTCAdaptationMode adaptationMode;

/**
 * Flag que indica se deve adaptar automaticamente ao formato da câmera nativa
 */
@property (nonatomic, assign) BOOL autoAdaptToCameraEnabled;

/**
 * Keep-alive timer para manter a conexão WebSocket ativa
 */
@property (nonatomic, strong) NSTimer *keepAliveTimer;

/**
 * Timer para tentativas de reconexão automática
 */
@property (nonatomic, strong) NSTimer *reconnectionTimer;

/**
 * Contador de tentativas de reconexão
 */
@property (nonatomic, assign) int reconnectionAttempts;

/**
 * Flag que indica se uma reconexão está em andamento
 */
@property (nonatomic, assign) BOOL isReconnecting;

/**
 * Timer para monitoramento de recursos
 */
@property (nonatomic, strong) dispatch_source_t resourceMonitorTimer;

/**
 * Timer para coleta de estatísticas
 */
@property (nonatomic, strong) NSTimer *statsInterval;

/**
 * Timer para keep-alive
 */
@property (nonatomic, strong) NSTimer *keepAliveInterval;

/**
 * Tarefa WebSocket atual
 */
@property (nonatomic, strong) NSURLSessionWebSocketTask *ws;

/**
 * Inicializa o gerenciador com referência à janela flutuante.
 * @param window FloatingWindow para atualização de interface.
 * @return Nova instância do gerenciador.
 */
- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;

/**
 * Inicia a conexão WebRTC.
 * Configura WebRTC, conecta ao servidor de sinalização e inicia a negociação.
 */
- (void)startWebRTC;

/**
 * Encerra a conexão WebRTC.
 * Libera todos os recursos e fecha conexões.
 * @param userInitiated Indica se a desconexão foi solicitada pelo usuário
 */
- (void)stopWebRTC:(BOOL)userInitiated;

/**
 * Envia uma mensagem de despedida (bye) para o servidor WebRTC.
 * Utilizado para informar ao servidor sobre uma desconexão iminente.
 */
- (void)sendByeMessage;

/**
 * Coleta estatísticas de qualidade da conexão WebRTC.
 * @return Dicionário contendo estatísticas como RTT, perdas de pacotes, etc.
 */
- (NSDictionary *)getConnectionStats;

/**
 * Remove o renderizador de vídeo da track atual.
 * Útil para limpar a visualização quando desconectar.
 * @param renderer O renderizador a ser removido (tipicamente videoView da FloatingWindow).
 */
- (void)removeRendererFromVideoTrack:(id<RTCVideoRenderer>)renderer;

/**
 * Obtém a estimativa atual de taxa de quadros (FPS).
 * @return Taxa de quadros estimada (frames por segundo).
 */
- (float)getEstimatedFps;

/**
 * Adapta-se à câmera nativa com a posição especificada.
 * @param position Posição da câmera (frontal/traseira).
 */
- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position;

/**
 * Define a resolução alvo para adaptação.
 * @param resolution Dimensões da resolução desejada.
 */
- (void)setTargetResolution:(CMVideoDimensions)resolution;

/**
 * Define a taxa de quadros alvo para adaptação.
 * @param frameRate Taxa de quadros desejada em FPS.
 */
- (void)setTargetFrameRate:(float)frameRate;

/**
 * Obtém o último frame como CMSampleBuffer para injeção em AVCaptureSession.
 * @return CMSampleBufferRef formatado para compatibilidade com câmera nativa.
 */
- (CMSampleBufferRef)getLatestVideoSampleBuffer;

/**
 * Obtém o último frame como CMSampleBuffer com formato específico.
 * @param format Formato de pixel desejado para o buffer.
 * @return CMSampleBufferRef formatado conforme especificado.
 */
- (CMSampleBufferRef)getLatestVideoSampleBufferWithFormat:(IOSPixelFormat)format;

/**
 * Configura o módulo para enviar informações de compatibilidade iOS ao servidor.
 * Isso ajuda na otimização dos parâmetros do servidor para máxima compatibilidade.
 * @param enable Se TRUE, envia informações de capacidades do iOS para o servidor.
 */
- (void)setIOSCompatibilitySignaling:(BOOL)enable;

@end

#endif /* WEBRTCMANAGER_H */
