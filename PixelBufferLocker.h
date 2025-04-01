#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@class WebRTCFrameConverter;

/**
 * Classe wrapper para garantir o desbloqueio seguro de CVPixelBuffer.
 * Implementa um padrão RAII adaptado para Objective-C.
 */
@interface PixelBufferLocker : NSObject

/**
 * O buffer de pixel que está sendo gerenciado.
 */
@property (nonatomic, assign, readonly) CVPixelBufferRef pixelBuffer;

/**
 * Indica se o buffer está atualmente bloqueado.
 */
@property (nonatomic, assign, readonly) BOOL locked;

/**
 * Referência fraca ao conversor para atualizar contadores.
 */
@property (nonatomic, weak, readonly) WebRTCFrameConverter *converter;

/**
 * Inicializa um novo locker com um buffer de pixel.
 * @param pixelBuffer O buffer a ser bloqueado/desbloqueado.
 * @param converter Referência ao conversor de frame.
 * @return Nova instância do locker.
 */
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          converter:(WebRTCFrameConverter *)converter;

/**
 * Bloqueia o buffer de pixel para acesso.
 * @return YES se o bloqueio foi bem-sucedido, NO caso contrário.
 */
- (BOOL)lock;

/**
 * Desbloqueia o buffer de pixel se estiver bloqueado.
 */
- (void)unlock;

@end
