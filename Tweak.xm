#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "WebRTCBufferInjector.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"

static FloatingWindow *floatingWindow;
static BOOL enableCameraReplacement = NO; // Desativado por padrão para modo observacional

// Função para configurar esta flag programaticamente
void setWebRTCCameraReplacementEnabled(BOOL enabled) {
    enableCameraReplacement = enabled;
    
    if (!enabled) {
        // Desativar imediatamente se a flag for desligada
        [[WebRTCBufferInjector sharedInstance] deactivateInjection];
    }
    
    writeLog(@"[WebRTCHook] Substituição de câmera %@", enabled ? @"ativada" : @"desativada");
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    
    // Configurar nível de log para máximo durante testes
    setLogLevel(5);
    writeLog(@"Tweak carregado em SpringBoard");
    
    // Inicializar com delay para garantir que o sistema esteja pronto
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        // Limpar log antigo antes de iniciar nova sessão
        clearLogFile();
        
        // Criar a janela flutuante
        floatingWindow = [[FloatingWindow alloc] init];
        
        // Inicializar o WebRTCManager e atribuí-lo à janela
        WebRTCManager *manager = [WebRTCManager sharedInstance];
        floatingWindow.webRTCManager = manager;
        
        // Configurar para adaptação automática ao formato da câmera
        manager.autoAdaptToCameraEnabled = YES;
        manager.adaptationMode = WebRTCAdaptationModeCompatibility;
        
        // Mostrar a janela após um pequeno delay para garantir inicialização completa
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [floatingWindow show];
            writeLog(@"Janela flutuante exibida em modo minimizado");
        });
    });
}

%end

%hook AVCaptureSession

- (void)startRunning {
    writeLog(@"[WebRTCHook] AVCaptureSession startRunning interceptado");
    
    // Verificar se esta sessão já esteve ativa antes
    static NSMutableSet *activeSessions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activeSessions = [NSMutableSet new];
    });
    
    BOOL isFirstTime = ![activeSessions containsObject:self];
    if (isFirstTime) {
        [activeSessions addObject:self];
        writeLog(@"[WebRTCHook] Primeira vez que esta sessão é iniciada (total: %lu)", (unsigned long)activeSessions.count);
    } else {
        writeLog(@"[WebRTCHook] Esta sessão já foi iniciada anteriormente");
    }
    
    // Guardar timestamp de início para diagnóstico
    NSDate *startTimestamp = [NSDate date];
    
    // Executar o método original primeiro para garantir funcionamento normal da câmera
    %orig;
    
    // Calcular quanto tempo levou para executar o método original
    NSTimeInterval origDuration = [[NSDate date] timeIntervalSinceDate:startTimestamp];
    writeLog(@"[WebRTCHook] AVCaptureSession startRunning executado com sucesso (duração: %.3fs)", origDuration);
    
    // Verificar se a sessão está realmente ativa
    if (!self.isRunning) {
        writeErrorLog(@"[WebRTCHook] Câmera não está ativa após startRunning (pode ser problema de permissões)");
        return;
    }
    
    // Registrar que nos conectamos a esta sessão e configurar monitoramento
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Iniciar monitoramento de estado da sessão para detectar se ela é terminada externamente
        [self addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:NULL];
        writeLog(@"[WebRTCHook] Monitoramento de estado da sessão iniciado");
    });
    
    // Configurar e ativar a injeção apenas depois de um delay significativo
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Verificar se a sessão ainda está ativa
        if (!self.isRunning) {
            writeErrorLog(@"[WebRTCHook] AVCaptureSession já não está mais rodando após 3 segundos!");
            return;
        }
        
        writeLog(@"[WebRTCHook] AVCaptureSession ainda está ativa após 3 segundos");
        
        // Se o WebRTCManager não estiver pronto, não tente configurar a substituição
        WebRTCManager *manager = [WebRTCManager sharedInstance];
        if (!manager) {
            writeLog(@"[WebRTCHook] WebRTCManager não está disponível, pulando configuração");
            return;
        }
        
        // Verificar se já está recebendo frames
        BOOL isReceivingFrames = manager.isReceivingFrames;
        writeLog(@"[WebRTCHook] WebRTCManager está recebendo frames: %@", isReceivingFrames ? @"SIM" : @"NÃO");
        
        // Configurar o WebRTCBufferInjector se necessário, mas sem ativar ainda
        WebRTCBufferInjector *injector = [WebRTCBufferInjector sharedInstance];
        if (!injector.isConfigured) {
            writeLog(@"[WebRTCHook] Configurando WebRTCBufferInjector para sessão");
            [injector configureWithSession:self];
            writeLog(@"[WebRTCHook] WebRTCBufferInjector configurado para a sessão");
        } else {
            writeLog(@"[WebRTCHook] WebRTCBufferInjector já configurado");
        }
        
        // Não ativar injeção - apenas configurar para observação
    });
}

- (void)stopRunning {
    writeLog(@"[WebRTCHook] AVCaptureSession stopRunning interceptado");
    
    // Desativar a substituição antes de parar a sessão
    [[WebRTCBufferInjector sharedInstance] deactivateInjection];
    
    // Remover observador se estiver observando
    @try {
        [self removeObserver:self forKeyPath:@"running"];
        writeLog(@"[WebRTCHook] Observador de sessão removido");
    } @catch (NSException *exception) {
        // Ignorar se não estiver observando
    }
    
    // Executar o método original
    %orig;
    
    writeLog(@"[WebRTCHook] AVCaptureSession stopRunning concluído");
}

// Método para monitorar mudanças de estado da sessão
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"running"]) {
        BOOL isRunning = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        writeLog(@"[WebRTCHook] AVCaptureSession estado mudou: running = %@", isRunning ? @"SIM" : @"NÃO");
        
        if (!isRunning) {
            // A sessão foi parada - verificar stack de chamadas se possível
            NSArray *callStackSymbols = [NSThread callStackSymbols];
            writeLog(@"[WebRTCHook] AVCaptureSession parou - Stack trace: %@", callStackSymbols);
        }
    }
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    writeLog(@"[WebRTCHook] setSampleBufferDelegate: %@ na queue: %@",
             [delegate class], queue ? [NSString stringWithFormat:@"%p", queue] : @"nil");
    
    // Registrar o delegate original para referência, mas sem substituir ainda
    WebRTCBufferInjector *injector = [WebRTCBufferInjector sharedInstance];
    [injector registerOriginalDelegate:delegate queue:queue];
    
    // Modo observacional: Não substituir o delegate original
    // Apenas chamar o método original para monitorar
    %orig;
    
    writeLog(@"[WebRTCHook] setSampleBufferDelegate concluído com delegate original");
    
    // Iniciar monitoramento para saber quando o primeiro frame é processado
    static BOOL monitoringStarted = NO;
    if (!monitoringStarted && delegate && [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        monitoringStarted = YES;
        
        // Adicionar swizzling para o método didOutputSampleBuffer para monitorar frames
        Class delegateClass = [delegate class];
        SEL originalSelector = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        SEL swizzledSelector = @selector(webrtc_captureOutput:didOutputSampleBuffer:fromConnection:);
        
        Method originalMethod = class_getInstanceMethod(delegateClass, originalSelector);
        if (originalMethod) {
            // Implementar método swizzled
            IMP swizzledImplementation = imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                static int frameCount = 0;
                frameCount++;
                
                if (frameCount == 1 || frameCount % 30 == 0) {
                    writeLog(@"[WebRTCHook] Frame #%d processado pelo delegate original", frameCount);
                    
                    // Verificar informações do buffer
                    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
                    if (formatDescription) {
                        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                        OSType pixelFormat = CMFormatDescriptionGetMediaSubType(formatDescription);
                        writeLog(@"[WebRTCHook] Frame info: %dx%d, formato: %d",
                                dimensions.width, dimensions.height, (int)pixelFormat);
                    }
                }
                
                // Chamar implementação original
                ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))
                 objc_msgSend)(self, originalSelector, output, sampleBuffer, connection);
            });
            
            // Adicionar método swizzled à classe
            class_addMethod(delegateClass, swizzledSelector, swizzledImplementation, method_getTypeEncoding(originalMethod));
            
            // Trocar implementações
            Method swizzledMethod = class_getInstanceMethod(delegateClass, swizzledSelector);
            method_exchangeImplementations(originalMethod, swizzledMethod);
            
            writeLog(@"[WebRTCHook] Monitoramento de frames iniciado com delegate: %@", delegateClass);
        }
    }
}

%end

%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    writeLog(@"[WebRTCHook] setVideoOrientation: %d", (int)videoOrientation);
    
    // Informar o WebRTCManager sobre a mudança de orientação
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    if (manager) {
        [manager adaptOutputToVideoOrientation:(int)videoOrientation];
    }
    
    %orig;
}

- (void)setVideoMirrored:(BOOL)videoMirrored {
    writeLog(@"[WebRTCHook] setVideoMirrored: %d", videoMirrored);
    
    // Informar o WebRTCManager sobre o espelhamento
    WebRTCManager *manager = [WebRTCManager sharedInstance];
    if (manager) {
        [manager setVideoMirrored:videoMirrored];
    }
    
    %orig;
}

%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    
    // Parar preview e liberar recursos
    if (floatingWindow) {
        [floatingWindow hide];
        if (floatingWindow.webRTCManager) {
            [floatingWindow.webRTCManager stopWebRTC:YES];
        }
    }
    
    // Desativar injeção de buffer se estiver ativa
    WebRTCBufferInjector *injector = [WebRTCBufferInjector sharedInstance];
    if (injector.isActive) {
        [injector deactivateInjection];
    }
    
    // Liberar referência
    floatingWindow = nil;
}
