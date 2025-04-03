#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

NSString *const kCameraChangeNotification = @"AVCaptureDeviceSubjectAreaDidChangeNotification";

@interface WebRTCManager ()
@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, assign) NSTimeInterval lastFrameReceivedTime;
@property (nonatomic, assign) BOOL userRequestedDisconnect;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, assign) AVCaptureDevicePosition currentCameraPosition;
@property (nonatomic, assign) OSType currentCameraFormat;
@property (nonatomic, assign) CMVideoDimensions currentCameraResolution;
@property (nonatomic, assign) BOOL iosCompatibilitySignalingEnabled;
@property (nonatomic, strong, readwrite) WebRTCFrameConverter *frameConverter;
@property (nonatomic, strong) NSTimer *statsTimer;
@end

@implementation WebRTCManager

#pragma mark - Initialization & Lifecycle
- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        _floatingWindow = window;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _reconnectAttempts = 0;
        _userRequestedDisconnect = NO;
        _serverIP = @"192.168.0.178";
        _adaptationMode = WebRTCAdaptationModeCompatibility;
        _autoAdaptToCameraEnabled = YES;
        _iosCompatibilitySignalingEnabled = YES;
        _frameConverter = [[WebRTCFrameConverter alloc] init];
        _currentCameraPosition = AVCaptureDevicePositionUnspecified;
        _currentCameraFormat = 0;
        _currentCameraResolution.width = 0;
        _currentCameraResolution.height = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleCameraChange:)
                                                     name:kCameraChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleLowMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        writeLog(@"[WebRTCManager] Inicializado com suporte otimizado para formatos iOS");
    }
    return self;
}

- (void)handleAppDidEnterBackground {
    writeLog(@"[WebRTCManager] Aplicativo entrou em background, realizando limpeza preventiva");
    if (self.state == WebRTCManagerStateConnected) {
        if (self.frameConverter) {
            [self.frameConverter clearSampleBufferCache];
            [self.frameConverter forceReleaseAllSampleBuffers];
            [self.frameConverter performSafeCleanup];
        }
        @autoreleasepool {
        }
    }
}

- (void)handleAppWillEnterForeground {
    writeLog(@"[WebRTCManager] Aplicativo retornou ao foreground");
    if (self.state == WebRTCManagerStateConnected) {
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] Conexão perdida durante background, reconectando...");
            self.state = WebRTCManagerStateReconnecting;
            [self attemptReconnection];
        } else {
            @try {
                [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Erro no ping após retorno do background: %@", error);
                        self.state = WebRTCManagerStateReconnecting;
                        [self attemptReconnection];
                    }
                }];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Exceção ao enviar ping: %@", e);
                self.state = WebRTCManagerStateReconnecting;
                [self attemptReconnection];
            }
        }
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopWebRTC:YES];
    writeLog(@"[WebRTCManager] Objeto desalocado, recursos liberados");
}

#pragma mark - State Management
- (void)setState:(WebRTCManagerState)newState {
    if (_state == newState) {
        return;
    }
    WebRTCManagerState oldState = _state;
    [self willChangeValueForKey:@"state"];
    _state = newState;
    [self didChangeValueForKey:@"state"];
    writeLog(@"[WebRTCManager] Estado alterado: %@ -> %@",
             [self stateToString:oldState],
             [self stateToString:newState]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:newState]];
    });
}

- (NSString *)stateToString:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected: return @"Desconectado";
        case WebRTCManagerStateConnecting: return @"Conectando";
        case WebRTCManagerStateConnected: return @"Conectado";
        case WebRTCManagerStateError: return @"Erro";
        case WebRTCManagerStateReconnecting: return @"Reconectando";
        default: return @"Desconhecido";
    }
}

- (NSString *)statusMessageForState:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected:
            return @"Desconectado";
        case WebRTCManagerStateConnecting:
            return @"Conectando ao servidor...";
        case WebRTCManagerStateConnected: {
            NSString *formatInfo = @"";
            if (_frameConverter.detectedPixelFormat != IOSPixelFormatUnknown) {
                formatInfo = [NSString stringWithFormat:@" (%@)",
                             [WebRTCFrameConverter stringFromPixelFormat:_frameConverter.detectedPixelFormat]];
            }
            return self.isReceivingFrames ?
                [NSString stringWithFormat:@"Conectado - Recebendo stream%@", formatInfo] :
                @"Conectado - Aguardando stream";
        }
        case WebRTCManagerStateError:
            return @"Erro de conexão";
        case WebRTCManagerStateReconnecting:
            return [NSString stringWithFormat:@"Reconectando (%d)...", self.reconnectAttempts];
        default:
            return @"Estado desconhecido";
    }
}

- (void)monitorNetworkStatus {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleNetworkStatusChange:)
                                                 name:@"com.apple.system.config.network_change"
                                               object:nil];
    writeLog(@"[WebRTCManager] Monitoramento de rede iniciado");
}

- (void)handleNetworkStatusChange:(NSNotification *)notification {
    writeLog(@"[WebRTCManager] Mudança de status de rede detectada");
    if (self.state == WebRTCManagerStateConnected || self.state == WebRTCManagerStateConnecting) {
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] WebSocket inativo após mudança de rede, iniciando reconexão");
            self.state = WebRTCManagerStateReconnecting;
            [self attemptReconnection];
        } else {
            @try {
                [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
                    if (error) {
                        writeLog(@"[WebRTCManager] Falha no ping após mudança de rede: %@", error);
                        self.state = WebRTCManagerStateReconnecting;
                        [self attemptReconnection];
                    } else {
                        writeLog(@"[WebRTCManager] Conexão confirmada após mudança de rede");
                    }
                }];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Exceção ao enviar ping: %@", e);
                self.state = WebRTCManagerStateReconnecting;
                [self attemptReconnection];
            }
        }
    }
}

#pragma mark - Camera Adaptation
- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position {
    _currentCameraPosition = position;
    if (!_autoAdaptToCameraEnabled) {
        writeLog(@"[WebRTCManager] Adaptação automática desativada, ignorando mudança de câmera");
        return;
    }
    writeLog(@"[WebRTCManager] Adaptando para câmera %@",
             position == AVCaptureDevicePositionFront ? @"frontal" : @"traseira");
    OSType format;
    CMVideoDimensions resolution;
    if (position == AVCaptureDevicePositionFront) {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        resolution.width = 1280;
        resolution.height = 720;
    } else {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        resolution.width = 1920;
        resolution.height = 1080;
    }
    _currentCameraFormat = format;
    _currentCameraResolution = resolution;
    [_frameConverter adaptToNativeCameraFormat:format resolution:resolution];
    [self updateFormatInfoInUI];
}

- (void)setTargetResolution:(CMVideoDimensions)resolution {
    [_frameConverter setTargetResolution:resolution];
}

- (void)setTargetFrameRate:(float)frameRate {
    [_frameConverter setTargetFrameRate:frameRate];
}

- (void)setAutoAdaptToCameraEnabled:(BOOL)enabled {
    _autoAdaptToCameraEnabled = enabled;
    writeLog(@"[WebRTCManager] Adaptação automática de câmera %@",
             enabled ? @"ativada" : @"desativada");
    if (enabled && _currentCameraPosition != AVCaptureDevicePositionUnspecified) {
        [self adaptToNativeCameraWithPosition:_currentCameraPosition];
    }
}

- (void)handleCameraChange:(NSNotification *)notification {
    if (!_autoAdaptToCameraEnabled) return;
    AVCaptureDevice *device = notification.object;
    if ([device hasMediaType:AVMediaTypeVideo]) {
        writeLog(@"[WebRTCManager] Detectada mudança na câmera: %@", device.localizedName);
        [self adaptToNativeCameraWithPosition:device.position];
    }
}

- (void)updateFormatInfoInUI {
    if (!self.floatingWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:self.state]];
        if ([self.floatingWindow respondsToSelector:@selector(updateFormatInfo:)]) {
            NSString *formatInfo = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
            [self.floatingWindow performSelector:@selector(updateFormatInfo:) withObject:formatInfo];
        }
    });
}

#pragma mark - Connection Management
- (void)startWebRTC {
    @try {
        if (self.state == WebRTCManagerStateConnected || self.state == WebRTCManagerStateConnecting) {
            writeLog(@"[WebRTCManager] Já está conectado ou conectando, ignorando chamada");
            return;
        }
        if (self.serverIP == nil || self.serverIP.length == 0) {
            writeLog(@"[WebRTCManager] IP do servidor inválido, usando padrão");
            self.serverIP = @"192.168.0.178"; // Default IP
        }
        self.userRequestedDisconnect = NO;
        writeLog(@"[WebRTCManager] Iniciando WebRTC (Modo: %@)",
                [self adaptationModeToString:self.adaptationMode]);
        self.state = WebRTCManagerStateConnecting;
        [self cleanupResources];
        [self configureWebRTC];
        [self connectWebSocket];
        [self startStatsTimer];
        __weak typeof(self) weakSelf = self;
        dispatch_queue_t monitorQueue = dispatch_queue_create("com.webrtc.resourcemonitor", DISPATCH_QUEUE_SERIAL);
        if (self.resourceMonitorTimer) {
            dispatch_source_cancel(self.resourceMonitorTimer);
            self.resourceMonitorTimer = nil;
        }
        self.resourceMonitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, monitorQueue);
        dispatch_source_set_timer(self.resourceMonitorTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(self.resourceMonitorTimer, ^{
            if (weakSelf.frameConverter) {
                [weakSelf checkResourceBalance];
                [weakSelf monitorVideoStatistics];
                [weakSelf.frameConverter checkForResourceLeaks];
            }
        });
        dispatch_resume(self.resourceMonitorTimer);
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao iniciar WebRTC: %@", exception);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Erro ao iniciar WebRTC"];
        });
        self.state = WebRTCManagerStateError;
    }
}

- (void)configureWebRTC {
    @try {
        writeLog(@"[WebRTCManager] Configurando WebRTC com otimizações para iOS");
        RTCConfiguration *config = [[RTCConfiguration alloc] init];
        config.iceServers = @[
            [[RTCIceServer alloc] initWithURLStrings:@[
                @"stun:stun.l.google.com:19302",
                @"stun:stun1.l.google.com:19302",
                @"stun:stun2.l.google.com:19302",
                @"stun:stun3.l.google.com:19302"
            ]]
        ];
        config.iceTransportPolicy = RTCIceTransportPolicyAll;
        config.bundlePolicy = RTCBundlePolicyMaxBundle;
        config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
        config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
        config.candidateNetworkPolicy = RTCCandidateNetworkPolicyAll;
        config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
        config.iceCandidatePoolSize = 2;
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        if (!decoderFactory) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar decoderFactory");
            return;
        }
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        if (!encoderFactory) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar encoderFactory");
            return;
        }
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                  decoderFactory:decoderFactory];
        if (!self.factory) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar PeerConnectionFactory");
            return;
        }
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                          initWithMandatoryConstraints:@{
                                              @"OfferToReceiveVideo": @"true",
                                              @"OfferToReceiveAudio": @"false"
                                          }
                                          optionalConstraints:@{
                                              @"DtlsSrtpKeyAgreement": @"true",
                                              @"RtpDataChannels": @"false",
                                              @"internalSctpDataChannels": @"false"
                                          }];
        self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                               constraints:constraints
                                                                  delegate:self];
        if (!self.peerConnection) {
            writeErrorLog(@"[WebRTCManager] Falha ao criar conexão peer");
            return;
        }
        [self monitorNetworkStatus];
        writeLog(@"[WebRTCManager] Conexão peer criada com sucesso");
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCManager] Exceção ao configurar WebRTC: %@", exception);
        self.state = WebRTCManagerStateError;
    }
}

- (void)stopWebRTC:(BOOL)userInitiated {
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
    }
    writeLog(@"[WebRTCManager] Parando WebRTC (solicitado pelo usuário: %@)",
            userInitiated ? @"sim" : @"não");
    if (self.frameConverter) {
        [self.frameConverter performSafeCleanup];
    }
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        [self sendByeMessage];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self cleanupResources];
        });
    } else {
        [self cleanupResources];
    }
}

- (void)handleLowMemoryWarning {
    writeLog(@"[WebRTCManager] Aviso de memória baixa recebido");
    if (self.frameConverter) {
        [self.frameConverter performSafeCleanup];
    }
}

- (void)cleanupResources {
    writeLog(@"[WebRTCManager] Realizando limpeza completa de recursos");
    if (self.frameConverter) {
        [self.frameConverter reset];
        [self.frameConverter performSafeCleanup];
        if (!self.isReconnecting) {
            [self removeRendererFromVideoTrack:self.frameConverter];
            self.frameConverter = nil;
        }
    }
    [self stopStatsTimer];
    if (_resourceMonitorTimer) {
        dispatch_source_cancel(_resourceMonitorTimer);
        _resourceMonitorTimer = nil;
    }
    self.isReceivingFrames = NO;
    if (self.floatingWindow) {
        self.floatingWindow.isReceivingFrames = NO;
    }
    if (self.videoTrack) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.floatingWindow respondsToSelector:@selector(videoView)]) {
                    RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                    if (videoView) {
                        @try {
                            [self.videoTrack removeRenderer:videoView];
                        } @catch (NSException *e) {
                            writeLog(@"[WebRTCManager] Exceção ao remover videoView do track: %@", e);
                        }
                        videoView.backgroundColor = [UIColor blackColor];
                    }
                }
            });
        }
        if (self.frameConverter) {
            @try {
                [self.videoTrack removeRenderer:self.frameConverter];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Exceção ao remover frameConverter do track: %@", e);
            }
        }
        self.videoTrack = nil;
    }
    if (self.webSocketTask) {
        @try {
            NSURLSessionWebSocketTask *taskToCancel = self.webSocketTask;
            self.webSocketTask = nil;
            [taskToCancel cancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao cancelar webSocketTask: %@", e);
        }
    }
    if (self.session) {
        @try {
            NSURLSession *sessionToInvalidate = self.session;
            self.session = nil;
            [sessionToInvalidate invalidateAndCancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao invalidar session: %@", e);
        }
    }
    if (self.peerConnection) {
        @try {
            RTCPeerConnection *connectionToClose = self.peerConnection;
            self.peerConnection = nil;
            [connectionToClose close];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao fechar peerConnection: %@", e);
        }
    }
    self.factory = nil;
    self.roomId = nil;
    self.clientId = nil;
    if (self.state != WebRTCManagerStateReconnecting || self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
    }
    @autoreleasepool {
    }
    writeLog(@"[WebRTCManager] Limpeza de recursos concluída");
}

#pragma mark - Timer Management
- (void)startStatsTimer {
    [self stopStatsTimer];
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(collectStats)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)stopStatsTimer {
    if (self.statsTimer) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
}

- (void)collectStats {
    if (!self.peerConnection) {
        return;
    }
    [self monitorVideoStatistics];
}

#pragma mark - WebSocket Connection
- (void)connectWebSocket {
    @try {
        NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
        NSURL *url = [NSURL URLWithString:urlString];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 60.0;
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = 60.0;
        sessionConfig.timeoutIntervalForResource = 120.0;
        if (self.session) {
            [self.session invalidateAndCancel];
        }
        self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                     delegate:self
                                                delegateQueue:[NSOperationQueue mainQueue]];
        self.webSocketTask = [self.session webSocketTaskWithRequest:request];
        [self receiveWebSocketMessage];
        [self.webSocketTask resume];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendJoinMessage];
        });
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCManager] Exceção ao conectar WebSocket: %@", exception);
        self.state = WebRTCManagerStateError;
    }
}

- (void)sendJoinMessage {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        NSMutableDictionary *joinMessage = [@{
            @"type": @"join",
            @"roomId": self.roomId ?: @"ios-camera",
            @"deviceType": @"ios",
            @"reconnect": @(self.reconnectAttempts > 0)
        } mutableCopy];
        if (self.iosCompatibilitySignalingEnabled) {
            joinMessage[@"capabilities"] = [self getiOSCapabilitiesInfo];
        }
        [self sendWebSocketMessage:joinMessage];
        writeLog(@"[WebRTCManager] Enviada mensagem de JOIN para a sala: %@", self.roomId ?: @"ios-camera");
    }
}

- (NSDictionary *)getiOSCapabilitiesInfo {
    return @{
        @"preferredPixelFormats": @[
            @"420f",
            @"420v",
            @"BGRA"
        ],
        @"preferredCodec": @"H264",
        @"preferredH264Profiles": @[
            @"42e01f",
            @"42001f",
            @"640c1f"
        ],
        @"adaptationMode": [self adaptationModeToString:self.adaptationMode],
        @"supportedResolutions": @[
            @{@"width": @1920, @"height": @1080},
            @{@"width": @1280, @"height": @720},
            @{@"width": @3840, @"height": @2160}
        ],
        @"currentFormat": [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat],
        @"deviceInfo": @{
            @"model": [[UIDevice currentDevice] model],
            @"systemVersion": [[UIDevice currentDevice] systemVersion]
        }
    };
}

- (NSString *)adaptationModeToString:(WebRTCAdaptationMode)mode {
    switch (mode) {
        case WebRTCAdaptationModeAuto:
            return @"auto";
        case WebRTCAdaptationModePerformance:
            return @"performance";
        case WebRTCAdaptationModeQuality:
            return @"quality";
        case WebRTCAdaptationModeCompatibility:
            return @"compatibility";
        default:
            return @"unknown";
    }
}

- (void)startKeepAliveTimer {
    if (_keepAliveTimer) {
        [_keepAliveTimer invalidate];
        _keepAliveTimer = nil;
    }
    _keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(sendKeepAlive)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_keepAliveTimer forMode:NSRunLoopCommonModes];
    [self sendKeepAlive];
}

- (void)sendKeepAlive {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
            if (error) {
                writeErrorLog(@"[WebRTCManager] Erro ao receber pong: %@", error);
            }
        }];
        [self sendWebSocketMessage:@{
            @"type": @"ping",
            @"roomId": self.roomId ?: @"ios-camera",
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
            @"deviceInfo": @{
                @"reconnectAttempts": @(self.reconnectAttempts),
                @"isReceivingFrames": @(self.isReceivingFrames)
            }
        }];
        writeVerboseLog(@"[WebRTCManager] Enviando mensagem keep-alive (ping)");
    }
}

- (void)sendByeMessage {
    @try {
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] Não foi possível enviar 'bye', WebSocket não está conectado");
            return;
        }
        writeLog(@"[WebRTCManager] Enviando mensagem 'bye' para o servidor");
        NSDictionary *byeMessage = @{
            @"type": @"bye",
            @"roomId": self.roomId ?: @"ios-camera"
        };
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:byeMessage options:0 error:&error];
        if (error) {
            writeErrorLog(@"[WebRTCManager] Erro ao serializar mensagem bye: %@", error);
            return;
        }
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                    completionHandler:^(NSError * _Nullable sendError) {
            if (sendError) {
                writeErrorLog(@"[WebRTCManager] Erro ao enviar bye: %@", sendError);
            } else {
                writeLog(@"[WebRTCManager] Mensagem 'bye' enviada com sucesso");
            }
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    } @catch (NSException *exception) {
        writeErrorLog(@"[WebRTCManager] Exceção ao enviar bye: %@", exception);
    }
}

- (void)sendWebSocketMessage:(NSDictionary *)message {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        writeLog(@"[WebRTCManager] Tentativa de enviar mensagem com WebSocket não conectado");
        return;
    }
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:&error];
    if (error) {
        writeLog(@"[WebRTCManager] Erro ao serializar mensagem JSON: %@", error);
        return;
    }
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                    completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar mensagem WebSocket: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao receber mensagem WebSocket: %@", error);
            if (weakSelf.webSocketTask.state != NSURLSessionTaskStateRunning && !weakSelf.userRequestedDisconnect) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateError;
                    if (!weakSelf.userRequestedDisconnect) {
                        [weakSelf startReconnectionTimer];
                    }
                });
            }
            return;
        }
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *jsonData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                     options:0
                                                                       error:&jsonError];
            if (jsonError) {
                writeLog(@"[WebRTCManager] Erro ao analisar mensagem JSON: %@", jsonError);
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleWebSocketMessage:jsonDict];
            });
        }
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
        }
    }];
}

- (void)handleWebSocketMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if (!type) {
        writeLog(@"[WebRTCManager] Mensagem recebida sem tipo");
        return;
    }
    writeLog(@"[WebRTCManager] Mensagem recebida: %@", type);
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    } else if ([type isEqualToString:@"answer"]) {
        [self handleAnswerMessage:message];
    } else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleCandidateMessage:message];
    } else if ([type isEqualToString:@"user-joined"]) {
        NSString *deviceType = message[@"deviceType"];
        if ([deviceType isEqualToString:@"web"]) {
            writeLog(@"[WebRTCManager] Transmissor web detectado: %@", message[@"userId"]);
        } else {
            writeLog(@"[WebRTCManager] Novo usuário entrou na sala: %@", message[@"userId"]);
        }
    } else if ([type isEqualToString:@"user-left"]) {
        writeLog(@"[WebRTCManager] Usuário saiu da sala: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"ping"]) {
        [self sendWebSocketMessage:@{
            @"type": @"pong",
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
            @"roomId": self.roomId ?: @"ios-camera"
        }];
        writeVerboseLog(@"[WebRTCManager] Respondeu ao ping com pong");
    } else if ([type isEqualToString:@"pong"]) {
        writeVerboseLog(@"[WebRTCManager] Pong recebido do servidor");
        self.reconnectionAttempts = 0;
        if (self.isReconnecting) {
            self.isReconnecting = NO;
            self.state = WebRTCManagerStateConnected;
            writeLog(@"[WebRTCManager] Conexão confirmada via pong durante reconexão");
        }
    } else if ([type isEqualToString:@"room-info"]) {
        writeVerboseLog(@"[WebRTCManager] Informações da sala recebidas: %@", message[@"clients"]);
    } else if ([type isEqualToString:@"error"]) {
        writeLog(@"[WebRTCManager] Erro recebido do servidor: %@", message[@"message"]);
        [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Erro: %@", message[@"message"]]];
    } else if ([type isEqualToString:@"ios-capabilities-update"]) {
        [self handleIOSCapabilitiesUpdate:message];
    } else {
        writeLog(@"[WebRTCManager] Tipo de mensagem desconhecido: %@", type);
    }
}

- (void)handleIOSCapabilitiesUpdate:(NSDictionary *)message {
    if (!message[@"capabilities"]) return;
    NSDictionary *capabilities = message[@"capabilities"];
    writeLog(@"[WebRTCManager] Recebidas capacidades de outro dispositivo iOS: %@", capabilities);
    if (capabilities[@"preferredPixelFormats"]) {
        NSArray *formats = capabilities[@"preferredPixelFormats"];
        writeLog(@"[WebRTCManager] Formatos de pixel preferidos pelo outro dispositivo: %@", formats);
    }
}

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Recebida oferta, mas não há conexão peer");
        return;
    }
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Oferta recebida sem SDP");
        return;
    }
    [self logSdpDetails:sdp type:@"Offer"];
    if (message[@"offerInfo"]) {
        NSDictionary *offerInfo = message[@"offerInfo"];
        BOOL optimizedForIOS = [offerInfo[@"optimizedForIOS"] boolValue];
        if (optimizedForIOS) {
            writeLog(@"[WebRTCManager] Oferta tem otimizações específicas para iOS");
        }
    }
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao definir descrição remota: %@", error);
            return;
        }
        writeLog(@"[WebRTCManager] Descrição remota definida com sucesso, criando resposta");
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        } optionalConstraints:nil];
        [weakSelf.peerConnection answerForConstraints:constraints
                               completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro ao criar resposta: %@", error);
                return;
            }
            [weakSelf logSdpDetails:sdp.sdp type:@"Answer"];
            NSMutableDictionary *answerMetadata = [NSMutableDictionary dictionary];
            if (weakSelf.iosCompatibilitySignalingEnabled) {
                answerMetadata[@"pixelFormat"] = [WebRTCFrameConverter stringFromPixelFormat:weakSelf.frameConverter.detectedPixelFormat];
                answerMetadata[@"h264Profile"] = @"42e01f";
                answerMetadata[@"adaptationMode"] = [weakSelf adaptationModeToString:weakSelf.adaptationMode];
            }
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro ao definir descrição local: %@", error);
                    return;
                }
                NSMutableDictionary *responseMessage = [@{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
                    @"roomId": weakSelf.roomId ?: @"ios-camera",
                    @"senderDeviceType": @"ios"
                } mutableCopy];
                if (weakSelf.iosCompatibilitySignalingEnabled) {
                    responseMessage[@"answerMetadata"] = answerMetadata;
                }
                [weakSelf sendWebSocketMessage:responseMessage];
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateConnected;
                });
            }];
        }];
    }];
}

- (void)handleAnswerMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Resposta recebida, mas não há conexão peer");
        return;
    }
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Resposta recebida sem SDP");
        return;
    }
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao definir descrição remota (resposta): %@", error);
            return;
        }
        writeLog(@"[WebRTCManager] Resposta remota definida com sucesso");
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.state = WebRTCManagerStateConnected;
        });
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Candidato recebido, mas não há conexão peer");
        return;
    }
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        writeLog(@"[WebRTCManager] Candidato recebido com parâmetros inválidos");
        return;
    }
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                         sdpMLineIndex:[sdpMLineIndex intValue]
                                                                sdpMid:sdpMid];
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao adicionar candidato Ice: %@", error);
            return;
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket conectado");
    self.reconnectAttempts = 0;
    if (!self.userRequestedDisconnect) {
        self.roomId = self.roomId ?: @"ios-camera";
        NSMutableDictionary *joinMessage = [@{
            @"type": @"join",
            @"roomId": self.roomId,
            @"deviceType": @"ios"
        } mutableCopy];
        if (self.iosCompatibilitySignalingEnabled) {
            joinMessage[@"capabilities"] = [self getiOSCapabilitiesInfo];
        }
        [self sendWebSocketMessage:joinMessage];
        writeLog(@"[WebRTCManager] Enviada mensagem de JOIN para a sala: %@", self.roomId);
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    writeLog(@"[WebRTCManager] WebSocket fechado com código: %ld, motivo: %@", (long)closeCode, reasonStr);
    if (!self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        if ([error.domain isEqualToString:NSURLErrorDomain] &&
            (error.code == NSURLErrorTimedOut || error.code == NSURLErrorNetworkConnectionLost)) {
            writeLog(@"[WebRTCManager] Timeout ou perda de conexão detectado: %@", error);
            if (!self.isReconnecting && !self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateReconnecting;
                [self startReconnectionTimer];
            }
        } else {
            writeLog(@"[WebRTCManager] WebSocket completou com erro: %@", error);
            
            if (!self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateError;
                [self startReconnectionTimer];
            }
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate
- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato Ice gerado: %@", candidate.sdp);
    [self sendWebSocketMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomId ?: @"ios-camera"
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCManager] Candidatos Ice removidos: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *stateString = [self iceConnectionStateToString:newState];
    writeLog(@"[WebRTCManager] Estado da conexão Ice alterado: %@", stateString);
    switch (newState) {
        case RTCIceConnectionStateConnected:
        case RTCIceConnectionStateCompleted:
            self.state = WebRTCManagerStateConnected;
            self.reconnectionAttempts = 0;
            self.isReconnecting = NO;
            break;
        case RTCIceConnectionStateFailed:
        case RTCIceConnectionStateDisconnected:
            if (!self.userRequestedDisconnect && !self.isReconnecting) {
                [self startReconnectionTimer];
            }
            break;
        case RTCIceConnectionStateClosed:
            if (!self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateError;
            }
            break;
        default:
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    writeLog(@"[WebRTCManager] Estado de coleta Ice alterado: %@", [self iceGatheringStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {
    writeLog(@"[WebRTCManager] Estado de sinalização alterado: %@", [self signalingStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream adicionada: %@ (áudio: %lu, vídeo: %lu)",
            stream.streamId, (unsigned long)stream.audioTracks.count, (unsigned long)stream.videoTracks.count);
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        writeLog(@"[WebRTCManager] Faixa de vídeo recebida: %@", self.videoTrack.trackId);
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                if (videoView) {
                    [self.videoTrack addRenderer:videoView];
                    [self.videoTrack addRenderer:self.frameConverter];
                    UIActivityIndicatorView *loadingIndicator = [self.floatingWindow valueForKey:@"loadingIndicator"];
                    if (loadingIndicator) {
                        [loadingIndicator stopAnimating];
                    }
                    self.isReceivingFrames = YES;
                    self.floatingWindow.isReceivingFrames = YES;
                    [self.floatingWindow updateConnectionStatus:@"Conectado - Recebendo vídeo"];
                }
            });
        }
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream removida: %@", stream.streamId);
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
            if (videoView) {
                [self.videoTrack removeRenderer:videoView];
                [self.videoTrack removeRenderer:self.frameConverter];
            }
        }
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
    }
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Necessária renegociação");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCManager] Data channel aberto: %@", dataChannel.label);
}

#pragma mark - Helper Methods
- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state {
    switch (state) {
        case RTCIceConnectionStateNew: return @"Novo";
        case RTCIceConnectionStateChecking: return @"Verificando";
        case RTCIceConnectionStateConnected: return @"Conectado";
        case RTCIceConnectionStateCompleted: return @"Completo";
        case RTCIceConnectionStateFailed: return @"Falha";
        case RTCIceConnectionStateDisconnected: return @"Desconectado";
        case RTCIceConnectionStateClosed: return @"Fechado";
        case RTCIceConnectionStateCount: return @"Contagem";
        default: return @"Desconhecido";
    }
}

- (NSString *)iceGatheringStateToString:(RTCIceGatheringState)state {
    switch (state) {
        case RTCIceGatheringStateNew: return @"Novo";
        case RTCIceGatheringStateGathering: return @"Coletando";
        case RTCIceGatheringStateComplete: return @"Completo";
        default: return @"Desconhecido";
    }
}

- (NSString *)signalingStateToString:(RTCSignalingState)state {
    switch (state) {
        case RTCSignalingStateStable: return @"Estável";
        case RTCSignalingStateHaveLocalOffer: return @"Oferta Local";
        case RTCSignalingStateHaveLocalPrAnswer: return @"Pré-resposta Local";
        case RTCSignalingStateHaveRemoteOffer: return @"Oferta Remota";
        case RTCSignalingStateHaveRemotePrAnswer: return @"Pré-resposta Remota";
        case RTCSignalingStateClosed: return @"Fechado";
        default: return @"Desconhecido";
    }
}

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    if (self.peerConnection) {
        stats[@"connectionType"] = @"Desconhecido";
        stats[@"rtt"] = @"--";
        stats[@"packetsReceived"] = @"--";
        NSString *iceState = [self iceConnectionStateToString:self.peerConnection.iceConnectionState];
        stats[@"iceState"] = iceState;
        if (self.frameConverter.detectedPixelFormat != IOSPixelFormatUnknown) {
            stats[@"pixelFormat"] = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
            stats[@"processingMode"] = self.frameConverter.processingMode;
        }
        if (self.state == WebRTCManagerStateConnected) {
            stats[@"connectionType"] = self.isReceivingFrames ? @"Ativa" : @"Conectada (sem frames)";
            if (self.isReceivingFrames) {
                stats[@"rtt"] = @"~120ms";
                stats[@"packetsReceived"] = @"Sim";
            }
        } else {
            stats[@"connectionType"] = [self stateToString:self.state];
        }
    }
    return stats;
}

- (void)logSdpDetails:(NSString *)sdp type:(NSString *)type {
    if (!sdp) return;
    writeLog(@"[WebRTCManager] Analisando %@ SDP (%lu caracteres)", type, (unsigned long)sdp.length);
    NSString *videoInfo = @"não detectado";
    NSString *resolutionInfo = @"desconhecida";
    NSString *fpsInfo = @"desconhecido";
    NSString *codecInfo = @"desconhecido";
    NSString *pixelFormatInfo = @"desconhecido";
    if ([sdp containsString:@"m=video"]) {
        videoInfo = @"presente";
        NSRegularExpression *resRegex = [NSRegularExpression
                                        regularExpressionWithPattern:@"a=imageattr:.*send.*\\[x=([0-9]+)\\-?([0-9]*)?\\,y=([0-9]+)\\-?([0-9]*)?\\]"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
        NSArray *matches = [resRegex matchesInString:sdp
                                          options:0
                                            range:NSMakeRange(0, sdp.length)];
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches[0];
            if (match.numberOfRanges >= 5) {
                NSString *widthStr = [sdp substringWithRange:[match rangeAtIndex:1]];
                NSString *heightStr = [sdp substringWithRange:[match rangeAtIndex:3]];
                resolutionInfo = [NSString stringWithFormat:@"%@x%@", widthStr, heightStr];
            }
        }
        NSRegularExpression *fpsRegex = [NSRegularExpression
                                        regularExpressionWithPattern:@"a=framerate:([0-9]+)"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
        matches = [fpsRegex matchesInString:sdp
                                  options:0
                                    range:NSMakeRange(0, sdp.length)];
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches[0];
            if (match.numberOfRanges >= 2) {
                NSString *fps = [sdp substringWithRange:[match rangeAtIndex:1]];
                fpsInfo = [NSString stringWithFormat:@"%@fps", fps];
            }
        }
        if ([sdp containsString:@"H264"]) {
            codecInfo = @"H264";
        } else if ([sdp containsString:@"VP8"]) {
            codecInfo = @"VP8";
        } else if ([sdp containsString:@"VP9"]) {
            codecInfo = @"VP9";
        }
        if ([sdp containsString:@"420f"]) {
            pixelFormatInfo = @"YUV 4:2:0 full-range (420f)";
        } else if ([sdp containsString:@"420v"]) {
            pixelFormatInfo = @"YUV 4:2:0 video-range (420v)";
        } else if ([sdp containsString:@"BGRA"]) {
            pixelFormatInfo = @"32-bit BGRA";
        }
    }
    NSString *bitrateInfo = @"não especificado";
    NSRegularExpression *bitrateRegex = [NSRegularExpression
                                      regularExpressionWithPattern:@"b=AS:([0-9]+)"
                                                           options:NSRegularExpressionCaseInsensitive
                                                             error:nil];
    NSArray *matches = [bitrateRegex matchesInString:sdp
                                          options:0
                                            range:NSMakeRange(0, sdp.length)];
    if (matches.count > 0) {
        NSTextCheckingResult *match = matches[0];
        if (match.numberOfRanges >= 2) {
            NSString *bitrate = [sdp substringWithRange:[match rangeAtIndex:1]];
            bitrateInfo = [NSString stringWithFormat:@"%@kbps", bitrate];
        }
    }
    writeLog(@"[WebRTCManager] Detalhes do %@ SDP: vídeo=%@, codec=%@, resolução=%@, fps=%@, bitrate=%@, formato=%@",
             type, videoInfo, codecInfo, resolutionInfo, fpsInfo, bitrateInfo, pixelFormatInfo);
    if ([codecInfo isEqualToString:@"H264"]) {
        NSRegularExpression *profileRegex = [NSRegularExpression
                                          regularExpressionWithPattern:@"profile-level-id=([0-9a-fA-F]+)"
                                                               options:NSRegularExpressionCaseInsensitive
                                                                 error:nil];
        matches = [profileRegex matchesInString:sdp
                                     options:0
                                       range:NSMakeRange(0, sdp.length)];
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches[0];
            if (match.numberOfRanges >= 2) {
                NSString *profile = [sdp substringWithRange:[match rangeAtIndex:1]];
                writeLog(@"[WebRTCManager] H264 profile-level-id: %@", profile);
                if ([profile isEqualToString:@"42e01f"] ||
                    [profile isEqualToString:@"42001f"] ||
                    [profile isEqualToString:@"640c1f"]) {
                    writeLog(@"[WebRTCManager] Perfil H264 compatível com iOS detectado");
                } else {
                    writeLog(@"[WebRTCManager] Perfil H264 não padronizado para iOS, pode causar problemas");
                }
            }
        }
    }
}

- (void)monitorVideoStatistics {
    if (!self.peerConnection) return;
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        NSDictionary<NSString *, RTCStatistics *> *stats = report.statistics;
        for (NSString *key in stats) {
            RTCStatistics *stat = stats[key];
            if ([stat.type isEqualToString:@"inbound-rtp"] &&
                [[stat.values[@"kind"] description] isEqualToString:@"video"]) {
                id framesReceivedObj = stat.values[@"framesReceived"];
                id packetsLostObj = stat.values[@"packetsLost"];
                id jitterObj = stat.values[@"jitter"];
                id bytesReceivedObj = stat.values[@"bytesReceived"];
                NSNumber *framesReceived = [framesReceivedObj isKindOfClass:[NSNumber class]] ? framesReceivedObj : nil;
                NSNumber *bytesReceived = [bytesReceivedObj isKindOfClass:[NSNumber class]] ? bytesReceivedObj : nil;
                static NSNumber *lastFramesReceived = nil;
                static NSNumber *lastBytesReceived = nil;
                static NSTimeInterval lastTime = 0;
                NSTimeInterval now = CACurrentMediaTime();
                NSTimeInterval timeDelta = now - lastTime;
                if (lastTime > 0 && timeDelta > 0 && lastFramesReceived && framesReceived) {
                    float frameRate = ([framesReceived floatValue] - [lastFramesReceived floatValue]) / timeDelta;
                    if (self.floatingWindow && frameRate > 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.floatingWindow.currentFps = frameRate;
                            if (self.floatingWindow.lastFrameSize.width > 0) {
                                [self updateFloatingWindowInfoWithFps:frameRate];
                            }
                        });
                    }
                    if (lastBytesReceived && bytesReceived) {
                        float bitrateMbps = ([bytesReceived doubleValue] - [lastBytesReceived doubleValue]) * 8.0 /
                                         (timeDelta * 1000000.0);
                        writeVerboseLog(@"[WebRTCManager] Estatísticas de vídeo: %.1f fps, %.2f Mbps, %.0f frames recebidos",
                                      frameRate, bitrateMbps, [framesReceived doubleValue]);
                        NSNumber *packetsLost = [packetsLostObj isKindOfClass:[NSNumber class]] ? packetsLostObj : nil;
                        NSNumber *jitter = [jitterObj isKindOfClass:[NSNumber class]] ? jitterObj : nil;
                        if (packetsLost && jitter) {
                            float jitterMs = [jitter floatValue] * 1000.0;
                            float packetLossRate = [packetsLost floatValue] / ([framesReceived floatValue] + 0.1) * 100.0; // %
                            writeVerboseLog(@"[WebRTCManager] Estatísticas de rede: Jitter=%.1fms, Perda=%.1f%%",
                                          jitterMs, packetLossRate);
                        }
                    }
                }
                lastFramesReceived = framesReceived;
                lastBytesReceived = bytesReceived;
                lastTime = now;
                break;
            }
        }
    }];
}

- (void)startReconnectionTimer {
    [self stopReconnectionTimer];
    if (self.reconnectionAttempts >= 5) {
        writeLog(@"[WebRTCManager] Número máximo de tentativas de reconexão atingido (5)");
        self.state = WebRTCManagerStateError;
        return;
    }
    self.reconnectionAttempts++;
    self.isReconnecting = YES;
    self.state = WebRTCManagerStateReconnecting;
    NSTimeInterval delay = pow(2, MIN(self.reconnectionAttempts, 4)); // 2, 4, 8, 16 segundos
    writeLog(@"[WebRTCManager] Tentando reconexão em %.0f segundos (tentativa %d/5)",
           delay, self.reconnectionAttempts);
    self.reconnectionTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                             target:self
                                                           selector:@selector(attemptReconnection)
                                                           userInfo:nil
                                                            repeats:NO];
}

- (void)stopReconnectionTimer {
    if (self.reconnectionTimer) {
        [self.reconnectionTimer invalidate];
        self.reconnectionTimer = nil;
    }
}

- (void)attemptReconnection {
    [self stopReconnectionTimer];
    writeLog(@"[WebRTCManager] Tentando reconectar ao servidor WebRTC...");
    NSString *currentRoomId = self.roomId;
    BOOL wasReceivingFrames = self.isReceivingFrames;
    [self cleanupForReconnection];
    self.roomId = currentRoomId;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self configureWebRTC];
        [self connectWebSocket];
        if (wasReceivingFrames && self.floatingWindow) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.floatingWindow updateConnectionStatus:@"Reconectando..."];
            });
        }
    });
}

- (void)cleanupForReconnection {
    writeLog(@"[WebRTCManager] Limpeza completa para reconexão");
    @try {
        if (self.statsInterval) {
            [self.statsInterval invalidate];
            self.statsInterval = nil;
        }
        if (self.reconnectionTimer) {
            [self.reconnectionTimer invalidate];
            self.reconnectionTimer = nil;
        }
        if (self.keepAliveInterval) {
            [self.keepAliveInterval invalidate];
            self.keepAliveInterval = nil;
        }
        if (self.resourceMonitorTimer) {
            dispatch_source_cancel(self.resourceMonitorTimer);
            self.resourceMonitorTimer = nil;
        }
        if (self.webSocketTask) {
            NSURLSessionWebSocketTask *oldWS = self.webSocketTask;
            self.webSocketTask = nil;
            @try {
                [oldWS cancel];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Erro ao cancelar WebSocket: %@", e);
            }
        }
        if (self.peerConnection) {
            RTCPeerConnection *oldConnection = self.peerConnection;
            self.peerConnection = nil;
            @try {
                [oldConnection close];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Erro ao fechar conexão peer: %@", e);
            }
        }
        if (self.videoTrack) {
            RTCVideoTrack *oldTrack = self.videoTrack;
            self.videoTrack = nil;
            
            if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
                RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                if (videoView) {
                    @try {
                        [oldTrack removeRenderer:videoView];
                    } @catch (NSException *e) {
                        writeLog(@"[WebRTCManager] Erro ao remover renderer: %@", e);
                    }
                }
            }
            
            if (self.frameConverter) {
                @try {
                    [oldTrack removeRenderer:self.frameConverter];
                } @catch (NSException *e) {
                    writeLog(@"[WebRTCManager] Erro ao remover frameConverter: %@", e);
                }
            }
        }
        if (self.frameConverter) {
            @try {
                [self.frameConverter clearSampleBufferCache];
                [self.frameConverter reset];
                [self.frameConverter forceReleaseAllSampleBuffers];
            } @catch (NSException *e) {
                writeLog(@"[WebRTCManager] Erro ao resetar frameConverter: %@", e);
            }
        }
        @autoreleasepool {}
        usleep(100000);
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção durante limpeza para reconexão: %@", exception);
    }
}

- (void)cleanupResourcesForReconnection {
    if (self.peerConnection) {
        RTCPeerConnection *oldConnection = self.peerConnection;
        self.peerConnection = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [oldConnection close];
        });
    }
    RTCVideoTrack *oldTrack = self.videoTrack;
    self.videoTrack = nil;
    if (oldTrack && self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
            if (videoView) {
                [oldTrack removeRenderer:videoView];
                [oldTrack removeRenderer:self.frameConverter];
            }
        });
    }
    NSURLSessionWebSocketTask *oldTask = self.webSocketTask;
    self.webSocketTask = nil;
    if (oldTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [oldTask cancel];
        });
    }
    NSURLSession *oldSession = self.session;
    self.session = nil;
    if (oldSession) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [oldSession invalidateAndCancel];
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.frameConverter) {
            [self.frameConverter checkForResourceLeaks];
            [self.frameConverter reset];
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            NSLog(@"Liberando pool de autoreleased objects");
        }
    });
}

- (void)updateFloatingWindowInfoWithFps:(float)fps {
    if (!self.floatingWindow) return;
    NSString *formatInfo = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
    NSString *infoText = [NSString stringWithFormat:@"%dx%d @ %.0ffps (%@)",
                         (int)self.floatingWindow.lastFrameSize.width,
                         (int)self.floatingWindow.lastFrameSize.height,
                         fps,
                         formatInfo];
    [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Recebendo stream: %@", infoText]];
}

- (void)removeRendererFromVideoTrack:(id<RTCVideoRenderer>)renderer {
    if (self.videoTrack && renderer) {
        [self.videoTrack removeRenderer:renderer];
    }
}

- (void)checkResourceBalance {
    if (self.frameConverter) {
        NSInteger sampleBufferDiff = self.frameConverter.totalSampleBuffersCreated - self.frameConverter.totalSampleBuffersReleased;
        NSInteger pixelBufferDiff = self.frameConverter.totalPixelBuffersLocked - self.frameConverter.totalPixelBuffersUnlocked;
        static int consecutiveDetections = 0;
        if (sampleBufferDiff > 5 || pixelBufferDiff > 5) {
            writeWarningLog(@"[WebRTCManager] Desbalanceamento de recursos detectado - Buffers: %ld, PixelBuffers: %ld",
                           (long)sampleBufferDiff, (long)pixelBufferDiff);
            [self.frameConverter performSafeCleanup];
            consecutiveDetections++;
            if (consecutiveDetections >= 3) {
                writeWarningLog(@"[WebRTCManager] Desbalanceamento persistente, forçando reset completo");
                [self.frameConverter reset];
                consecutiveDetections = 0;
            }
        } else {
            consecutiveDetections = 0;
        }
    }
}

#pragma mark - Sample Buffer Generation
- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    CMSampleBufferRef buffer = [self.frameConverter getLatestSampleBuffer];
    return buffer;
}

- (CMSampleBufferRef)getLatestVideoSampleBufferWithFormat:(IOSPixelFormat)format {
    return [self.frameConverter getLatestSampleBufferWithFormat:format];
}

- (void)setIOSCompatibilitySignaling:(BOOL)enable {
    _iosCompatibilitySignalingEnabled = enable;
    writeLog(@"[WebRTCManager] Sinalização de compatibilidade iOS %@", enable ? @"ativada" : @"desativada");
}

- (CMSampleBufferRef)getLatestVideoSampleBufferWithOriginalMetadata:(CMSampleBufferRef)originalBuffer {
    if (!self.frameConverter) return NULL;
    CMSampleBufferRef webrtcBuffer = [self.frameConverter getLatestSampleBuffer];
    if (!webrtcBuffer) return NULL;
    if (!originalBuffer) return webrtcBuffer;
    if (![self.frameConverter respondsToSelector:@selector(extractMetadataFromSampleBuffer:)] ||
        ![self.frameConverter respondsToSelector:@selector(applyMetadataToSampleBuffer:metadata:)]) {
        return webrtcBuffer;
    }
    NSDictionary *metadata = [self.frameConverter extractMetadataFromSampleBuffer:originalBuffer];
    if (!metadata) return webrtcBuffer;
    BOOL success = [self.frameConverter applyMetadataToSampleBuffer:webrtcBuffer metadata:metadata];
    if (!success) {
        writeWarningLog(@"[WebRTCManager] Não foi possível aplicar metadados ao buffer WebRTC");
    }
    return webrtcBuffer;
}

- (BOOL)isReadyForCameraFeedReplacement {
    if (!self.isReceivingFrames || !self.frameConverter) {
        return NO;
    }
    if (self.frameConverter.frameCount < 30) {
        return NO;
    }
    float minAcceptableFps = 15.0; // Mínimo aceitável para substituição
    if (self.frameConverter.currentFps < minAcceptableFps) {
        return NO;
    }
    if (self.frameConverter.detectedPixelFormat == IOSPixelFormatUnknown) {
        return NO;
    }
    if (self.frameConverter.droppedFrameCount > 0) {
        float dropRate = (float)self.frameConverter.droppedFrameCount / self.frameConverter.frameCount;
        if (dropRate > 0.2) {
            return NO;
        }
    }
    return YES;
}

- (void)updateNativeCameraFrameRate:(float)fps {
    if (fps <= 0) return;
    if (self.frameConverter) {
        [self.frameConverter setTargetFrameRate:fps];
        writeLog(@"[WebRTCManager] Taxa de frames da câmera nativa atualizada: %.1ffps", fps);
    }
}

- (float)getEstimatedFps {
    if (self.frameConverter && self.frameConverter.currentFps > 0) {
        return self.frameConverter.currentFps;
    }
    __block float estimatedFps = 0.0f;
    if (!self.isReceivingFrames) {
        return 0.0f;
    }
    if (!self.peerConnection) {
        return 0.0f;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        NSDictionary<NSString *, RTCStatistics *> *stats = report.statistics;
        for (NSString *key in stats) {
            RTCStatistics *stat = stats[key];
            if ([stat.type isEqualToString:@"inbound-rtp"] &&
                [[stat.values[@"kind"] description] isEqualToString:@"video"]) {
                id framesPerSecondObj = stat.values[@"framesPerSecond"];
                if (framesPerSecondObj && [framesPerSecondObj isKindOfClass:[NSNumber class]]) {
                    NSNumber *framesPerSecond = (NSNumber *)framesPerSecondObj;
                    estimatedFps = [framesPerSecond floatValue];
                    writeVerboseLog(@"[WebRTCManager] FPS encontrado nas estatísticas: %.1f", estimatedFps);
                } else {
                    id framesReceivedObj = stat.values[@"framesReceived"];
                    id timestampObj = stat.values[@"timestamp"];
                    static NSNumber *lastFramesReceived = nil;
                    static NSNumber *lastTimestamp = nil;
                    if (framesReceivedObj && [framesReceivedObj isKindOfClass:[NSNumber class]] &&
                        timestampObj && [timestampObj isKindOfClass:[NSNumber class]]) {
                        NSNumber *framesReceived = (NSNumber *)framesReceivedObj;
                        NSNumber *timestamp = (NSNumber *)timestampObj;
                        if (lastFramesReceived && lastTimestamp) {
                            double framesDelta = [framesReceived doubleValue] - [lastFramesReceived doubleValue];
                            double timeDelta = ([timestamp doubleValue] - [lastTimestamp doubleValue]) / 1000.0; // ms para s
                            if (timeDelta > 0) {
                                estimatedFps = framesDelta / timeDelta;
                                writeVerboseLog(@"[WebRTCManager] FPS calculado: %.1f (frames: %.0f, tempo: %.3fs)",
                                             estimatedFps, framesDelta, timeDelta);
                            }
                        }
                        lastFramesReceived = framesReceived;
                        lastTimestamp = timestamp;
                    }
                }
                break;
            }
        }
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    return estimatedFps;
}

- (void)setCaptureSessionClock:(CMClockRef)clock {
    if (self.frameConverter) {
        if ([self.frameConverter respondsToSelector:@selector(setCaptureSessionClock:)]) {
            [self.frameConverter setCaptureSessionClock:clock];
            writeLog(@"[WebRTCManager] Configurado relógio de sessão para o frameConverter");
        } else {
            writeWarningLog(@"[WebRTCManager] frameConverter não implementa setCaptureSessionClock:");
        }
    }
}

@end
