#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void writeLog(NSString *format, ...);
void writeErrorLog(NSString *format, ...);
void writeWarningLog(NSString *format, ...);
void writeCriticalLog(NSString *format, ...);
void writeVerboseLog(NSString *format, ...);
void writeLogWithLevel(int level, NSString *message);
void setLogLevel(int level);
int getLogLevel(void);
void setLogPath(NSString *path);
NSString *getLogPath(void);
void clearLogFile(void);
NSDictionary *getLogStats(void);
NSString *getLogContents(int maxLines);

#ifdef __cplusplus
}
#endif

#endif /* LOGGER_H */
