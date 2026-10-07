#import <Foundation/Foundation.h>

NSData *LYHTTPSDataForURL(NSString *urlString,
                          NSString *userAgent,
                          NSInteger *statusCode,
                          NSString **errorString);
