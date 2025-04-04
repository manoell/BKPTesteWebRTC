#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "WebRTCStream.h"
#import <UIKit/UIKit.h>
#import "logger.h"

static FloatingWindow *floatingWindow;

// Hook para AVCaptureVideoPreviewLayer para detectar e mascarar camadas
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer {
    %orig;
    
    // Registra a camada de preview para uso posterior
    Class webRTCStreamClass = NSClassFromString(@"WebRTCStream");
    if (webRTCStreamClass) {
        id stream = [webRTCStreamClass performSelector:@selector(sharedInstance)];
        if (stream && [stream respondsToSelector:@selector(registerPreviewLayer:)]) {
            [stream performSelector:@selector(registerPreviewLayer:) withObject:self];
            writeLog(@"[Tweak] Camada de preview registrada");
        }
    }
}
%end

// Hook para intercepção do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    writeLog(@"[Tweak] AVCaptureVideoDataOutput::setSampleBufferDelegate - Configurando interception");
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        writeLog(@"[Tweak] Delegate ou queue nulos, chamando método original sem modificações");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooked = [NSMutableArray new];
    });
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if (![hooked containsObject:className]) {
        writeLog(@"[Tweak] Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Verifica se o WebRTCStream está ativo
                Class webRTCStreamClass = NSClassFromString(@"WebRTCStream");
                if (webRTCStreamClass) {
                    id stream = [webRTCStreamClass performSelector:@selector(sharedInstance)];
                    if (stream &&
                        [stream respondsToSelector:@selector(isStreamActive)] &&
                        [stream performSelector:@selector(isStreamActive)]) {
                        
                        if ([stream respondsToSelector:@selector(getCurrentFrame:)]) {
                            // Usamos NSInvocation para chamar o método com um argumento C, não Objective-C
                            NSMethodSignature *signature = [stream methodSignatureForSelector:@selector(getCurrentFrame:)];
                            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                            [invocation setSelector:@selector(getCurrentFrame:)];
                            [invocation setTarget:stream];
                            [invocation setArgument:&sampleBuffer atIndex:2]; // O índice 2 corresponde ao primeiro argumento
                            [invocation invoke];
                            
                            // Obtém o resultado
                            CMSampleBufferRef newBuffer = NULL;
                            [invocation getReturnValue:&newBuffer];
                            
                            // Chama o método original com o buffer substituído ou o original em caso de falha
                            if (newBuffer) {
                                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer, connection);
                            }
                        }
                    }
                }
                
                // Se o hook não está ativo ou falhou, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

// Modificar FloatingWindow para ativar/desativar WebRTCStream
%hook FloatingWindow
- (void)togglePreview:(UIButton *)sender {
    %orig;
    
    // Verifica se o método resultou em ativação do preview
    BOOL isActive = [self valueForKey:@"isPreviewActive"] != nil ? [[self valueForKey:@"isPreviewActive"] boolValue] : NO;
    
    // Ativa/desativa o stream WebRTC para substituição da câmera
    Class webRTCStreamClass = NSClassFromString(@"WebRTCStream");
    if (webRTCStreamClass) {
        id stream = [webRTCStreamClass performSelector:@selector(sharedInstance)];
        if (stream && [stream respondsToSelector:@selector(setActiveStream:)]) {
            // Chama setActiveStream: usando NSInvocation para evitar warnings do compilador
            NSMethodSignature *signature = [stream methodSignatureForSelector:@selector(setActiveStream:)];
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setSelector:@selector(setActiveStream:)];
            [invocation setTarget:stream];
            [invocation setArgument:&isActive atIndex:2]; // O índice 2 corresponde ao primeiro argumento (0: self, 1: _cmd)
            [invocation invoke];
            
            writeLog(@"[Tweak] WebRTCStream %@", isActive ? @"ativado" : @"desativado");
        }
    }
}
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    writeLog(@"Tweak carregado em SpringBoard");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        clearLogFile();
        floatingWindow = [[FloatingWindow alloc] init];
        WebRTCManager *manager = [[WebRTCManager alloc] initWithFloatingWindow:floatingWindow];
        floatingWindow.webRTCManager = manager;
        manager.autoAdaptToCameraEnabled = YES;
        manager.adaptationMode = WebRTCAdaptationModeCompatibility;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [floatingWindow show];
            writeLog(@"Janela flutuante exibida em modo minimizado");
        });
    });
}
%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    if (floatingWindow) {
        [floatingWindow hide];
        if (floatingWindow.webRTCManager) {
            [floatingWindow.webRTCManager stopWebRTC:YES];
        }
    }
    floatingWindow = nil;
}
