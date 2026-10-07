#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSData *LYHTTPSDataForURL(NSString *urlString,
                          NSString *userAgent,
                          NSString *acceptHeader,
                          NSInteger *statusCode,
                          NSInteger *retryAfterSeconds,
                          NSString **errorString);

#ifdef __cplusplus
}
#endif
