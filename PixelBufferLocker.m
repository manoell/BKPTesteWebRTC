#import "PixelBufferLocker.h"
#import "WebRTCFrameConverter.h"
#import "logger.h"

@implementation PixelBufferLocker

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          converter:(WebRTCFrameConverter *)converter {
    self = [super init];
    if (self) {
        _pixelBuffer = pixelBuffer;
        _converter = converter;
        _locked = NO;
    }
    return self;
}

- (BOOL)lock {
    if (!_pixelBuffer) {
        return NO;
    }
    
    // Verificar se já está bloqueado para evitar locks múltiplos
    if (_locked) {
        return YES;
    }
    
    CVReturn result = CVPixelBufferLockBaseAddress(_pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (result == kCVReturnSuccess) {
        _locked = YES;
        if (_converter) {
            // Incrementar contador de locks diretamente
            [_converter incrementPixelBufferLockCount];
        }
        return YES;
    } else {
        writeErrorLog(@"[PixelBufferLocker] Falha ao bloquear CVPixelBuffer: %d", (int)result);
        return NO;
    }
}

- (void)unlock {
    if (!_pixelBuffer) {
        return;
    }
    
    // Verificar se realmente está bloqueado para evitar unlocks múltiplos
    if (!_locked) {
        return;
    }
    
    CVReturn result = CVPixelBufferUnlockBaseAddress(_pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (result == kCVReturnSuccess) {
        _locked = NO;
        if (_converter) {
            // Incrementar contador de unlocks diretamente
            [_converter incrementPixelBufferUnlockCount];
        }
    } else {
        writeErrorLog(@"[PixelBufferLocker] Falha ao desbloquear CVPixelBuffer: %d", (int)result);
    }
}

- (void)dealloc {
    // Garantir desbloqueio ao liberar o objeto
    [self unlock];
}

@end
