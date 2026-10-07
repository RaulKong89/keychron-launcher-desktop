#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSData *LYHTTPSDataForURL(NSString *urlString,
                          NSString *userAgent,
                          NSInteger *statusCode,
                          NSString **errorString);

#ifdef __cplusplus
}
#endif
