#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

NSString *const kCameraChangeNotification = @"AVCaptureDeviceSubjectAreaDidChangeNotification";

@interface WebRTCManager ()

@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, assign) BOOL userRequestedDisconnect;
@property (nonatomic, assign) BOOL isReconnecting;
@property (nonatomic, assign) NSTimeInterval lastFrameReceivedTime;

// WebRTC e WebSocket
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;

// Timers
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, strong) NSTimer *reconnectionTimer;
@property (nonatomic, strong) NSTimer *statsTimer;

// Câmera
@property (nonatomic, assign) AVCaptureDevicePosition currentCameraPosition;
@property (nonatomic, assign) OSType currentCameraFormat;
@property (nonatomic, assign) CMVideoDimensions currentCameraResolution;
@property (nonatomic, assign) BOOL iosCompatibilitySignalingEnabled;
@property (nonatomic, strong, readwrite) WebRTCFrameConverter *frameConverter;

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
        _serverIP = @"192.168.0.178"; // IP padrão
        _adaptationMode = WebRTCAdaptationModeCompatibility;
        _autoAdaptToCameraEnabled = YES;
        _iosCompatibilitySignalingEnabled = YES;
        _frameConverter = [[WebRTCFrameConverter alloc] init];
        _currentCameraPosition = AVCaptureDevicePositionUnspecified;
        _currentCameraFormat = 0;
        _currentCameraResolution.width = 0;
        _currentCameraResolution.height = 0;
        
        // Configurar observadores de notificação
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopWebRTC:YES];
    writeLog(@"[WebRTCManager] Objeto desalocado, recursos liberados");
}

#pragma mark - Event Handlers

- (void)handleAppDidEnterBackground {
    writeLog(@"[WebRTCManager] Aplicativo entrou em background");
    if (self.state == WebRTCManagerStateConnected && self.frameConverter) {
        [self.frameConverter clearSampleBufferCache];
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

- (void)handleLowMemoryWarning {
    writeLog(@"[WebRTCManager] Aviso de memória baixa recebido");
    if (self.frameConverter) {
        [self.frameConverter clearSampleBufferCache];
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

- (void)updateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.floatingWindow respondsToSelector:@selector(updateConnectionStatus:)]) {
            [self.floatingWindow updateConnectionStatus:status];
        }
    });
}

#pragma mark - Camera Adaptation

- (void)adaptToNativeCameraWithPosition:(AVCaptureDevicePosition)position {
    _currentCameraPosition = position;
    
    if (!_autoAdaptToCameraEnabled) {
        writeLog(@"[WebRTCManager] Adaptação automática desativada");
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

- (void)updateFormatInfoInUI {
    if (!self.floatingWindow) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:self.state]];
        
        if ([self.floatingWindow respondsToSelector:@selector(updateFormatInfo:)]) {
            NSString *formatInfo = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
            [self.floatingWindow performSelector:@selector(updateFormatInfo:) withObject:formatInfo];
        }
        
        if ([self.floatingWindow respondsToSelector:@selector(updateProcessingMode:)]) {
            NSString *processingMode = self.frameConverter.processingMode ?: @"Desconhecido";
            [self.floatingWindow performSelector:@selector(updateProcessingMode:) withObject:processingMode];
        }
    });
}

#pragma mark - WebRTC Setup & Management

- (void)startWebRTC {
    @try {
        if (self.state == WebRTCManagerStateConnected || self.state == WebRTCManagerStateConnecting) {
            writeLog(@"[WebRTCManager] Já está conectado ou conectando, ignorando chamada");
            return;
        }
        
        if (self.serverIP == nil || self.serverIP.length == 0) {
            self.serverIP = @"192.168.0.178"; // IP padrão
        }
        
        self.userRequestedDisconnect = NO;
        writeLog(@"[WebRTCManager] Iniciando WebRTC (Modo: %@)", [self adaptationModeToString:self.adaptationMode]);
        
        self.state = WebRTCManagerStateConnecting;
        [self cleanupResources];
        [self configureWebRTC];
        [self connectWebSocket];
        [self startStatsTimer];
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
        writeLog(@"[WebRTCManager] Configurando WebRTC");
        
        RTCConfiguration *config = [[RTCConfiguration alloc] init];
        config.iceServers = @[
            [[RTCIceServer alloc] initWithURLStrings:@[
                @"stun:stun.l.google.com:19302",
                @"stun:stun1.l.google.com:19302"
            ]]
        ];
        
        config.bundlePolicy = RTCBundlePolicyMaxBundle;
        config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
        config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
        
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                  decoderFactory:decoderFactory];
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                          initWithMandatoryConstraints:@{
                                              @"OfferToReceiveVideo": @"true",
                                              @"OfferToReceiveAudio": @"false"
                                          }
                                          optionalConstraints:@{
                                              @"DtlsSrtpKeyAgreement": @"true"
                                          }];
        
        self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                               constraints:constraints
                                                                  delegate:self];
        
        writeLog(@"[WebRTCManager] Conexão peer criada com sucesso");
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao configurar WebRTC: %@", exception);
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
        [self.frameConverter clearSampleBufferCache];
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

- (void)cleanupResources {
    writeLog(@"[WebRTCManager] Realizando limpeza de recursos");
    
    // Limpar frame converter
    if (self.frameConverter) {
        [self.frameConverter reset];
        if (!self.isReconnecting) {
            [self removeRendererFromVideoTrack:self.frameConverter];
        }
    }
    
    // Parar timers
    [self stopStatsTimer];
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    if (self.reconnectionTimer) {
        [self.reconnectionTimer invalidate];
        self.reconnectionTimer = nil;
    }
    
    // Resetar flags
    self.isReceivingFrames = NO;
    if (self.floatingWindow) {
        self.floatingWindow.isReceivingFrames = NO;
    }
    
    // Remover track de vídeo
    if (self.videoTrack) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RTCMTLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                if (videoView) {
                    @try {
                        [self.videoTrack removeRenderer:videoView];
                    } @catch (NSException *e) {
                        writeLog(@"[WebRTCManager] Exceção ao remover videoView do track: %@", e);
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
    
    // Fechar conexão WebSocket
    if (self.webSocketTask) {
        @try {
            NSURLSessionWebSocketTask *taskToCancel = self.webSocketTask;
            self.webSocketTask = nil;
            [taskToCancel cancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao cancelar webSocketTask: %@", e);
        }
    }
    
    // Invalidar sessão
    if (self.session) {
        @try {
            NSURLSession *sessionToInvalidate = self.session;
            self.session = nil;
            [sessionToInvalidate invalidateAndCancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao invalidar session: %@", e);
        }
    }
    
    // Fechar conexão peer
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
    
    writeLog(@"[WebRTCManager] Limpeza de recursos concluída");
}

#pragma mark - Timer Management

- (void)startStatsTimer {
    [self stopStatsTimer];
    
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(monitorVideoStatistics)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)stopStatsTimer {
    if (self.statsTimer) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
}

- (void)startKeepAliveTimer {
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                         target:self
                                                       selector:@selector(sendKeepAlive)
                                                       userInfo:nil
                                                        repeats:YES];
    
    [[NSRunLoop mainRunLoop] addTimer:self.keepAliveTimer forMode:NSRunLoopCommonModes];
    [self sendKeepAlive];
}

- (void)sendKeepAlive {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        @try {
            [self.webSocketTask sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro ao receber pong: %@", error);
                }
            }];
            
            [self sendMessage:@{
                @"type": @"ping",
                @"roomId": self.roomId ?: @"ios-camera",
                @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000)
            }];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Exceção ao enviar ping: %@", e);
        }
    }
}

#pragma mark - WebSocket Connection

- (void)connectWebSocket {
    if (self.webSocketTask && self.webSocketTask.state != NSURLSessionTaskStateCompleted) {
        writeLog(@"[WebRTCManager] WebSocket já está conectado ou conectando");
        return;
    }
    
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 30.0;
    sessionConfig.timeoutIntervalForResource = 60.0;
    
    if (self.session) {
        [self.session invalidateAndCancel];
    }
    
    self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                delegate:self
                                           delegateQueue:[NSOperationQueue mainQueue]];
    
    self.webSocketTask = [self.session webSocketTaskWithRequest:request];
    [self receiveWebSocketMessage];
    [self.webSocketTask resume];
    
    // Enviar join após um pequeno delay para garantir que o WebSocket esteja pronto
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendJoinMessage];
    });
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
        
        [self sendMessage:joinMessage];
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
        @"currentFormat": [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat]
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

- (void)sendByeMessage {
    @try {
        if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
            writeLog(@"[WebRTCManager] Não foi possível enviar 'bye', WebSocket não está conectado");
            return;
        }
        
        writeLog(@"[WebRTCManager] Enviando mensagem 'bye' para o servidor");
        
        [self sendMessage:@{
            @"type": @"bye",
            @"roomId": self.roomId ?: @"ios-camera"
        }];
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao enviar bye: %@", exception);
    }
}

- (void)sendMessage:(NSDictionary *)message {
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
    } else if ([type isEqualToString:@"ping"]) {
        [self sendMessage:@{
            @"type": @"pong",
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
            @"roomId": self.roomId ?: @"ios-camera"
        }];
    } else if ([type isEqualToString:@"pong"]) {
        writeLog(@"[WebRTCManager] Pong recebido do servidor");
        self.reconnectAttempts = 0;
        if (self.isReconnecting) {
            self.isReconnecting = NO;
            self.state = WebRTCManagerStateConnected;
        }
    } else if ([type isEqualToString:@"room-info"]) {
        writeLog(@"[WebRTCManager] Informações da sala recebidas: %@", message[@"clients"]);
    } else if ([type isEqualToString:@"error"]) {
        writeLog(@"[WebRTCManager] Erro recebido do servidor: %@", message[@"message"]);
        [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Erro: %@", message[@"message"]]];
    } else if ([type isEqualToString:@"ios-capabilities-update"]) {
        [self handleIOSCapabilitiesUpdate:message];
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
                
                [weakSelf sendMessage:responseMessage];
                
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
        
        [self sendMessage:joinMessage];
        writeLog(@"[WebRTCManager] Enviada mensagem de JOIN para a sala: %@", self.roomId);
    }
    
    [self startKeepAliveTimer];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    writeLog(@"[WebRTCManager] WebSocket fechado com código: %ld, motivo: %@", (long)closeCode, reasonStr);
    
    if (!self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
        [self startReconnectionTimer];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCManager] WebSocket completou com erro: %@", error);
        
        if (!self.userRequestedDisconnect) {
            self.state = WebRTCManagerStateError;
            [self startReconnectionTimer];
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato Ice gerado: %@", candidate.sdp);
    
    [self sendMessage:@{
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
            self.reconnectAttempts = 0;
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

#pragma mark - Reconexão

- (void)startReconnectionTimer {
    [self stopReconnectionTimer];
    
    if (self.reconnectAttempts >= 5) {
        writeLog(@"[WebRTCManager] Número máximo de tentativas de reconexão atingido (5)");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    self.reconnectAttempts++;
    self.isReconnecting = YES;
    self.state = WebRTCManagerStateReconnecting;
    
    NSTimeInterval delay = pow(2, MIN(self.reconnectAttempts, 4)); // 2, 4, 8, 16 segundos
    
    writeLog(@"[WebRTCManager] Tentando reconexão em %.0f segundos (tentativa %d/5)",
           delay, self.reconnectAttempts);
    
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
    writeLog(@"[WebRTCManager] Limpeza para reconexão");
    
    if (self.webSocketTask) {
        @try {
            NSURLSessionWebSocketTask *oldWS = self.webSocketTask;
            self.webSocketTask = nil;
            [oldWS cancel];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Erro ao cancelar WebSocket: %@", e);
        }
    }
    
    if (self.peerConnection) {
        @try {
            RTCPeerConnection *oldConnection = self.peerConnection;
            self.peerConnection = nil;
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
            [self.frameConverter reset];
        } @catch (NSException *e) {
            writeLog(@"[WebRTCManager] Erro ao resetar frameConverter: %@", e);
        }
    }
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
        
        // Extrair resolução
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
        
        // Extrair FPS
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
        
        // Detectar codec
        if ([sdp containsString:@"H264"]) {
            codecInfo = @"H264";
        } else if ([sdp containsString:@"VP8"]) {
            codecInfo = @"VP8";
        } else if ([sdp containsString:@"VP9"]) {
            codecInfo = @"VP9";
        }
        
        // Detectar formato de pixel
        if ([sdp containsString:@"420f"]) {
            pixelFormatInfo = @"YUV 4:2:0 full-range (420f)";
        } else if ([sdp containsString:@"420v"]) {
            pixelFormatInfo = @"YUV 4:2:0 video-range (420v)";
        } else if ([sdp containsString:@"BGRA"]) {
            pixelFormatInfo = @"32-bit BGRA";
        }
    }
    
    // Extrair bitrate
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
                NSNumber *framesReceived = [framesReceivedObj isKindOfClass:[NSNumber class]] ? framesReceivedObj : nil;
                
                static NSNumber *lastFramesReceived = nil;
                static NSTimeInterval lastTime = 0;
                
                NSTimeInterval now = CACurrentMediaTime();
                NSTimeInterval timeDelta = now - lastTime;
                
                if (lastTime > 0 && timeDelta > 0 && lastFramesReceived && framesReceived) {
                    float frameRate = ([framesReceived floatValue] - [lastFramesReceived floatValue]) / timeDelta;
                    
                    if (self.floatingWindow && frameRate > 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.floatingWindow.currentFps = frameRate;
                            
                            if (self.floatingWindow.lastFrameSize.width > 0) {
                                NSString *formatInfo = [WebRTCFrameConverter stringFromPixelFormat:self.frameConverter.detectedPixelFormat];
                                NSString *infoText = [NSString stringWithFormat:@"%dx%d @ %.0ffps (%@)",
                                                   (int)self.floatingWindow.lastFrameSize.width,
                                                   (int)self.floatingWindow.lastFrameSize.height,
                                                   frameRate,
                                                   formatInfo];
                                
                                [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Recebendo stream: %@", infoText]];
                            }
                        });
                    }
                }
                
                lastFramesReceived = framesReceived;
                lastTime = now;
                
                break;
            }
        }
    }];
}

- (void)removeRendererFromVideoTrack:(id<RTCVideoRenderer>)renderer {
    if (self.videoTrack && renderer) {
        [self.videoTrack removeRenderer:renderer];
    }
}

- (CMSampleBufferRef)getLatestVideoSampleBuffer {
    return [self.frameConverter getLatestSampleBuffer];
}

- (CMSampleBufferRef)getLatestVideoSampleBufferWithFormat:(IOSPixelFormat)format {
    return [self.frameConverter getLatestSampleBufferWithFormat:format];
}

- (void)setIOSCompatibilitySignaling:(BOOL)enable {
    _iosCompatibilitySignalingEnabled = enable;
    writeLog(@"[WebRTCManager] Sinalização de compatibilidade iOS %@", enable ? @"ativada" : @"desativada");
}

- (float)getEstimatedFps {
    if (self.frameConverter) {
        return [self.frameConverter getEstimatedFps];
    }
    return 0.0;
}

@end
