#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Escreve uma mensagem de log com formatação (nível INFO).
 * As mensagens são registradas no console e, dependendo do nível de log,
 * em um arquivo de log em /var/tmp/testeWebRTC.log.
 *
 * @param format String de formato para a mensagem.
 * @param ... Argumentos variáveis para formatação.
 */
void writeLog(NSString *format, ...);

/**
 * Escreve mensagem de log com nível ERROR.
 *
 * @param format String de formato para a mensagem.
 * @param ... Argumentos variáveis para formatação.
 */
void writeErrorLog(NSString *format, ...);

/**
 * Escreve mensagem de log com nível WARNING.
 *
 * @param format String de formato para a mensagem.
 * @param ... Argumentos variáveis para formatação.
 */
void writeWarningLog(NSString *format, ...);

/**
 * Escreve mensagem de log com nível CRITICAL.
 *
 * @param format String de formato para a mensagem.
 * @param ... Argumentos variáveis para formatação.
 */
void writeCriticalLog(NSString *format, ...);

/**
 * Escreve mensagem de log com nível VERBOSE.
 *
 * @param format String de formato para a mensagem.
 * @param ... Argumentos variáveis para formatação.
 */
void writeVerboseLog(NSString *format, ...);

/**
 * Escreve uma mensagem de log com nível específico.
 *
 * @param level Nível de log (1-5).
 * @param message Mensagem para registrar.
 */
void writeLogWithLevel(int level, NSString *message);

/**
 * Define o nível de log.
 * 0 = Sem logging
 * 1 = Apenas erros críticos
 * 2 = Erros
 * 3 = Avisos e erros (padrão)
 * 4 = Informações, avisos e erros (com log em arquivo)
 * 5 = Verbose (tudo, com log em arquivo)
 *
 * @param level Nível de log (0-5).
 */
void setLogLevel(int level);

/**
 * Obtém o nível de log atual.
 *
 * @return Nível de log atual.
 */
int getLogLevel(void);

/**
 * Define o caminho do arquivo de log.
 * Por padrão é /var/tmp/testeWebRTC.log.
 *
 * @param path Caminho para o arquivo de log.
 */
void setLogPath(NSString *path);

/**
 * Obtém o caminho atual do arquivo de log.
 *
 * @return Caminho do arquivo de log.
 */
NSString *getLogPath(void);

/**
 * Limpa o arquivo de log atual.
 */
void clearLogFile(void);

/**
 * Obtém estatísticas sobre o sistema de logging.
 *
 * @return Dicionário com estatísticas como contadores por nível, tamanho do arquivo, etc.
 */
NSDictionary *getLogStats(void);

/**
 * Obtém o conteúdo atual do arquivo de log.
 *
 * @param maxLines Se > 0, limita o retorno às últimas N linhas do log.
 * @return String com o conteúdo do log ou mensagem de erro.
 */
NSString *getLogContents(int maxLines);

#ifdef __cplusplus
}
#endif

#endif /* LOGGER_H */
