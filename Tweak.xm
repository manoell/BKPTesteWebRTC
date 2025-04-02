#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import <UIKit/UIKit.h>
#import "logger.h"

static FloatingWindow *floatingWindow;

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
        WebRTCManager *manager = [[WebRTCManager alloc] initWithFloatingWindow:floatingWindow];
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
    
    // Liberar referência
    floatingWindow = nil;
}
