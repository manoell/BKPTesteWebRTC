#import "logger.h"
#import <UIKit/UIKit.h>

typedef NS_ENUM(int, LogLevel) {
    LogLevelNone = 0,
    LogLevelCritical = 1,
    LogLevelError = 2,
    LogLevelWarning = 3,
    LogLevelInfo = 4,
    LogLevelVerbose = 5
};

static int gLogLevel = 5;
static NSString *gLogPath = @"/var/tmp/testeWebRTC.log";
static NSLock *gLogLock = nil;
static const long long MAX_LOG_SIZE = 10 * 1024 * 1024;
static const int MAX_LOG_BACKUPS = 3;
static NSDictionary *gLogPrefixes = nil;
static NSDictionary *gLogColors = nil;
static NSDate *gSessionStartDate = nil;
static int gLogCounts[6] = {0, 0, 0, 0, 0, 0}; // Contadores para cada nível

static void rotateLogFiles(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:gLogPath]) {
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    NSString *oldestBackupPath = [NSString stringWithFormat:@"%@.%d", gLogPath, MAX_LOG_BACKUPS];
    [fileManager removeItemAtPath:oldestBackupPath error:nil];
    for (int i = MAX_LOG_BACKUPS - 1; i >= 1; i--) {
        NSString *currentPath = [NSString stringWithFormat:@"%@.%d", gLogPath, i];
        NSString *newPath = [NSString stringWithFormat:@"%@.%d", gLogPath, i + 1];
        if ([fileManager fileExistsAtPath:currentPath]) {
            [fileManager moveItemAtPath:currentPath toPath:newPath error:nil];
        }
    }
    NSString *backupPath = [NSString stringWithFormat:@"%@.1", gLogPath];
    if ([fileManager fileExistsAtPath:backupPath]) {
        [fileManager removeItemAtPath:backupPath error:nil];
    }
    NSError *moveError = nil;
    BOOL moveSucess = [fileManager moveItemAtPath:gLogPath toPath:backupPath error:&moveError];
    if (!moveSucess) {
        NSLog(@"[WebRTCTweak] Erro ao mover arquivo de log: %@", moveError);
        [fileManager removeItemAtPath:gLogPath error:nil];
    }
    [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *rotationNote = [NSString stringWithFormat:
                             @"\n=== LOG ROTACIONADO EM %@ ===\nArquivo anterior salvo como %@\n\n",
                             [formatter stringFromDate:[NSDate date]],
                             backupPath];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[rotationNote dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle closeFile];
}

__attribute__((constructor))
static void initialize() {
    gLogLock = [[NSLock alloc] init];
    gSessionStartDate = [NSDate date];
    gLogPrefixes = @{
        @(LogLevelCritical): @"[CRITICAL]",
        @(LogLevelError): @"[ERROR]",
        @(LogLevelWarning): @"[WARNING]",
        @(LogLevelInfo): @"[INFO]",
        @(LogLevelVerbose): @"[VERBOSE]"
    };
    gLogColors = @{
        @(LogLevelCritical): @"\033[1;31m",
        @(LogLevelError): @"\033[31m",
        @(LogLevelWarning): @"\033[33m",
        @(LogLevelInfo): @"\033[32m",
        @(LogLevelVerbose): @"\033[36m"
    };
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    UIDevice *device = [UIDevice currentDevice];
    NSString *sessionHeader = [NSString stringWithFormat:
                              @"\n\n=== NOVA SESSÃO - %@ ===\n"
                              @"Device: %@ (%@)\n"
                              @"iOS: %@\n"
                              @"Log Level: %d\n"
                              @"=================================\n\n",
                              [formatter stringFromDate:gSessionStartDate],
                              device.model,
                              device.systemName,
                              device.systemVersion,
                              gLogLevel];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL fileExists = [fileManager fileExistsAtPath:gLogPath];
    if (fileExists) {
        [gLogLock lock];
        @try {
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:gLogPath error:nil];
            NSNumber *fileSize = [attributes objectForKey:NSFileSize];
            if ([fileSize longLongValue] > MAX_LOG_SIZE) {
                rotateLogFiles();
            }
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[sessionHeader dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } @catch (NSException *e) {
            NSLog(@"[WebRTCTweak] Erro ao inicializar log: %@", e);
        } @finally {
            [gLogLock unlock];
        }
    } else {
        [sessionHeader writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void setLogLevel(int level) {
    if (level >= 0 && level <= 5) {
        gLogLevel = level;
        NSLog(@"[WebRTCTweak] Nível de log alterado para %d", level);
        if (level >= 1) {
            NSString *message = [NSString stringWithFormat:@"Nível de log alterado para %d", level];
            writeLogWithLevel(LogLevelInfo, message);
        }
    }
}

int getLogLevel(void) {
    return gLogLevel;
}

void setLogPath(NSString *path) {
    if (path && path.length > 0) {
        [gLogLock lock];
        @try {
            NSString *oldPath = gLogPath;
            gLogPath = [path copy];
            NSLog(@"[WebRTCTweak] Caminho de log alterado de %@ para %@", oldPath, path);
            if (gLogLevel >= 1) {
                NSString *message = [NSString stringWithFormat:@"Caminho de log alterado para %@", path];
                writeLogWithLevel(LogLevelInfo, message);
            }
        } @finally {
            [gLogLock unlock];
        }
    }
}

NSString *getLogPath(void) {
    return gLogPath;
}

NSDictionary *getLogStats(void) {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    [stats setObject:@(gLogCounts[LogLevelCritical]) forKey:@"critical"];
    [stats setObject:@(gLogCounts[LogLevelError]) forKey:@"error"];
    [stats setObject:@(gLogCounts[LogLevelWarning]) forKey:@"warning"];
    [stats setObject:@(gLogCounts[LogLevelInfo]) forKey:@"info"];
    [stats setObject:@(gLogCounts[LogLevelVerbose]) forKey:@"verbose"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:gLogPath]) {
        NSError *error = nil;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:gLogPath error:&error];
        if (!error) {
            NSNumber *fileSize = [attributes objectForKey:NSFileSize];
            [stats setObject:fileSize forKey:@"fileSize"];
            
            NSDate *modDate = [attributes objectForKey:NSFileModificationDate];
            [stats setObject:modDate forKey:@"lastModified"];
        }
    }
    [stats setObject:gSessionStartDate forKey:@"sessionStart"];
    NSTimeInterval sessionDuration = [[NSDate date] timeIntervalSinceDate:gSessionStartDate];
    [stats setObject:@(sessionDuration) forKey:@"sessionDuration"];
    return stats;
}

void clearLogFile(void) {
    [gLogLock lock];
    @try {
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[WebRTCTweak] Arquivo de log limpo: %@", gLogPath);
        for (int i = 0; i < 6; i++) {
            gLogCounts[i] = 0;
        }
        initialize();
    } @finally {
        [gLogLock unlock];
    }
}

void writeLogWithLevel(int level, NSString *message) {
    if (level < 1 || level > 5) {
        level = LogLevelInfo;
    }
    if (gLogLevel < level) {
        return;
    }
    @try {
        gLogCounts[level]++;
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
        NSString *threadIdentifier = [NSString stringWithFormat:@"%p", [NSThread currentThread]];
        NSString *levelPrefix = gLogPrefixes[@(level)] ?: @"";
        NSString *logMessage = [NSString stringWithFormat:@"[%@][%@]%@ %@\n",
                              timestamp,
                              threadIdentifier,
                              levelPrefix,
                              message];
        NSString *colorCode = gLogColors[@(level)] ?: @"";
        NSString *resetCode = @"\033[0m";
        NSLog(@"%@[WebRTCTweak] %@%@", colorCode, message, resetCode);
        [gLogLock lock];
        @try {
            NSString *directory = [gLogPath stringByDeletingLastPathComponent];
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSError *dirError = nil;
            if (![fileManager fileExistsAtPath:directory]) {
                [fileManager createDirectoryAtPath:directory
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&dirError];
                if (dirError) {
                    NSLog(@"[WebRTCTweak] Erro ao criar diretório de log: %@", dirError);
                }
            }
            if (![fileManager fileExistsAtPath:gLogPath]) {
                [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:gLogPath error:nil];
            NSNumber *fileSize = [attributes objectForKey:NSFileSize];
            if ([fileSize longLongValue] > MAX_LOG_SIZE) {
                rotateLogFiles();
            }
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (fileHandle == nil) {
                NSLog(@"[WebRTCTweak] Erro ao abrir arquivo de log");
                return;
            }
            @try {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
                [fileHandle closeFile];
            } @catch (NSException *e) {
                NSLog(@"[WebRTCTweak] Erro ao escrever log: %@", e);
            }
        } @finally {
            [gLogLock unlock];
        }
    } @catch (NSException *e) {
        NSLog(@"[WebRTCTweak] ERRO NO LOGGER: %@", e);
    }
}

void writeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    writeLogWithLevel(LogLevelInfo, message);
}

void writeErrorLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    writeLogWithLevel(LogLevelError, message);
}

void writeWarningLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    writeLogWithLevel(LogLevelWarning, message);
}

void writeCriticalLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    writeLogWithLevel(LogLevelCritical, message);
}

void writeVerboseLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    writeLogWithLevel(LogLevelVerbose, message);
}

NSString *getLogContents(int maxLines) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:gLogPath]) {
        return @"Arquivo de log não encontrado.";
    }
    NSError *error = nil;
    NSString *logContents = [NSString stringWithContentsOfFile:gLogPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:&error];
    if (error) {
        return [NSString stringWithFormat:@"Erro ao ler arquivo de log: %@", error.localizedDescription];
    }
    if (maxLines > 0) {
        NSArray *lines = [logContents componentsSeparatedByString:@"\n"];
        NSInteger startIndex = MAX(0, (NSInteger)lines.count - maxLines);
        NSArray *lastLines = [lines subarrayWithRange:NSMakeRange(startIndex, lines.count - startIndex)];
        return [lastLines componentsJoinedByString:@"\n"];
    }
    return logContents;
}
