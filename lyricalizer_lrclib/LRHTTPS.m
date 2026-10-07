#import "LRHTTPS.h"

#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/error.h>

#include <sys/socket.h>
#include <sys/time.h>
#include <string.h>
#include <stdlib.h>

static NSString * const LYCAPath = @"/Library/Application Support/LyricalizerLRCLIB/cacert.pem";

static NSString *LYMbedError(int code) {
    char buf[256];
    memset(buf, 0, sizeof(buf));
    mbedtls_strerror(code, buf, sizeof(buf) - 1);
    return [NSString stringWithFormat:@"%s (%d)", buf, code];
}

static NSData *LYDecodeChunked(NSData *body) {
    const unsigned char *bytes = (const unsigned char *)[body bytes];
    NSUInteger len = [body length];
    NSUInteger pos = 0;
    NSMutableData *out = [NSMutableData data];

    while (pos < len) {
        NSUInteger lineStart = pos;
        NSUInteger lineEnd = NSNotFound;
        while (pos + 1 < len) {
            if (bytes[pos] == '\r' && bytes[pos + 1] == '\n') {
                lineEnd = pos;
                break;
            }
            pos++;
        }
        if (lineEnd == NSNotFound) return nil;

        NSData *lineData = [NSData dataWithBytes:bytes + lineStart length:lineEnd - lineStart];
        NSString *line = [[[NSString alloc] initWithData:lineData encoding:NSASCIIStringEncoding] autorelease];
        if (!line) return nil;

        NSRange semicolon = [line rangeOfString:@";"];
        if (semicolon.location != NSNotFound) line = [line substringToIndex:semicolon.location];

        unsigned long chunkSize = strtoul([line UTF8String], NULL, 16);
        pos = lineEnd + 2;

        if (chunkSize == 0) break;
        if (pos + chunkSize > len) return nil;

        [out appendBytes:bytes + pos length:(NSUInteger)chunkSize];
        pos += (NSUInteger)chunkSize;

        if (pos + 1 >= len || bytes[pos] != '\r' || bytes[pos + 1] != '\n') return nil;
        pos += 2;
    }

    return out;
}

static BOOL LYHeaderContains(NSString *headers, NSString *needle) {
    return [[headers lowercaseString] rangeOfString:[needle lowercaseString]].location != NSNotFound;
}

NSData *LYHTTPSDataForURL(NSString *urlString,
                          NSString *userAgent,
                          NSInteger *statusCode,
                          NSString **errorString) {
    if (statusCode) *statusCode = 0;
    if (errorString) *errorString = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || ![[[url scheme] lowercaseString] isEqualToString:@"https"] || ![[url host] length]) {
        if (errorString) *errorString = @"Invalid HTTPS URL";
        return nil;
    }

    NSString *host = [url host];
    NSString *path = [url path];
    if (![path length]) path = @"/";
    if ([[url query] length]) path = [path stringByAppendingFormat:@"?%@", [url query]];

    mbedtls_net_context server;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt cacert;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_entropy_context entropy;

    mbedtls_net_init(&server);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_x509_crt_init(&cacert);
    mbedtls_ctr_drbg_init(&ctr_drbg);
    mbedtls_entropy_init(&entropy);

    int ret = 0;
    NSData *result = nil;
    NSString *failure = nil;

    const char *pers = "LyricalizerLRCLIB-iOS6";
    ret = mbedtls_ctr_drbg_seed(&ctr_drbg,
                                mbedtls_entropy_func,
                                &entropy,
                                (const unsigned char *)pers,
                                strlen(pers));
    if (ret != 0) {
        failure = [NSString stringWithFormat:@"RNG init failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    ret = mbedtls_x509_crt_parse_file(&cacert, [LYCAPath fileSystemRepresentation]);
    if (ret < 0) {
        failure = [NSString stringWithFormat:@"Embedded CA bundle unavailable: %@", LYMbedError(ret)];
        goto cleanup;
    }

    ret = mbedtls_ssl_config_defaults(&conf,
                                      MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        failure = [NSString stringWithFormat:@"TLS config failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&conf, &cacert, NULL);
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctr_drbg);
    mbedtls_ssl_conf_min_version(&conf, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3); // TLS 1.2

    ret = mbedtls_ssl_setup(&ssl, &conf);
    if (ret != 0) {
        failure = [NSString stringWithFormat:@"TLS setup failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    ret = mbedtls_ssl_set_hostname(&ssl, [host UTF8String]);
    if (ret != 0) {
        failure = [NSString stringWithFormat:@"TLS hostname failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    ret = mbedtls_net_connect(&server, [host UTF8String], "443", MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) {
        failure = [NSString stringWithFormat:@"Connection failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    struct timeval timeout;
    timeout.tv_sec = 8;
    timeout.tv_usec = 0;
    setsockopt(server.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(server.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    mbedtls_ssl_set_bio(&ssl, &server, mbedtls_net_send, mbedtls_net_recv, NULL);

    do {
        ret = mbedtls_ssl_handshake(&ssl);
    } while (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE);

    if (ret != 0) {
        failure = [NSString stringWithFormat:@"TLS handshake failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    uint32_t verifyFlags = mbedtls_ssl_get_verify_result(&ssl);
    if (verifyFlags != 0) {
        char info[512];
        memset(info, 0, sizeof(info));
        mbedtls_x509_crt_verify_info(info, sizeof(info) - 1, "", verifyFlags);
        failure = [NSString stringWithFormat:@"Certificate verification failed: %s", info];
        goto cleanup;
    }

    NSString *ua = [userAgent length] ? userAgent : @"Lyricalizer-LRCLIB/2.0";
    NSString *requestString = [NSString stringWithFormat:
        @"GET %@ HTTP/1.1\r\n"
         "Host: %@\r\n"
         "User-Agent: %@\r\n"
         "Lrclib-Client: %@\r\n"
         "Accept: application/json\r\n"
         "Accept-Encoding: identity\r\n"
         "Connection: close\r\n\r\n",
        path, host, ua, ua];

    NSData *requestData = [requestString dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *requestBytes = (const unsigned char *)[requestData bytes];
    size_t requestLength = [requestData length];
    size_t written = 0;

    while (written < requestLength) {
        ret = mbedtls_ssl_write(&ssl, requestBytes + written, requestLength - written);
        if (ret > 0) {
            written += (size_t)ret;
            continue;
        }
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        failure = [NSString stringWithFormat:@"HTTPS write failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    NSMutableData *raw = [NSMutableData data];
    unsigned char buffer[4096];

    for (;;) {
        ret = mbedtls_ssl_read(&ssl, buffer, sizeof(buffer));
        if (ret > 0) {
            [raw appendBytes:buffer length:(NSUInteger)ret];
            if ([raw length] > (4 * 1024 * 1024)) {
                failure = @"HTTP response too large";
                goto cleanup;
            }
            continue;
        }

        if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) break;
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;

        failure = [NSString stringWithFormat:@"HTTPS read failed: %@", LYMbedError(ret)];
        goto cleanup;
    }

    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange headerRange = [raw rangeOfData:separator options:0 range:NSMakeRange(0, [raw length])];
    if (headerRange.location == NSNotFound) {
        failure = @"Malformed HTTP response";
        goto cleanup;
    }

    NSData *headerData = [raw subdataWithRange:NSMakeRange(0, headerRange.location)];
    NSString *headers = [[[NSString alloc] initWithData:headerData encoding:NSISOLatin1StringEncoding] autorelease];
    if (!headers) {
        failure = @"Unreadable HTTP headers";
        goto cleanup;
    }

    NSArray *lines = [headers componentsSeparatedByString:@"\r\n"];
    if (![lines count]) {
        failure = @"Missing HTTP status";
        goto cleanup;
    }

    NSArray *statusParts = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
    NSInteger httpStatus = ([statusParts count] >= 2) ? [[statusParts objectAtIndex:1] integerValue] : 0;
    if (statusCode) *statusCode = httpStatus;

    NSUInteger bodyStart = headerRange.location + headerRange.length;
    NSData *body = bodyStart <= [raw length]
        ? [raw subdataWithRange:NSMakeRange(bodyStart, [raw length] - bodyStart)]
        : [NSData data];

    if (LYHeaderContains(headers, @"transfer-encoding: chunked")) {
        NSData *decoded = LYDecodeChunked(body);
        if (!decoded) {
            failure = @"Invalid chunked HTTP body";
            goto cleanup;
        }
        body = decoded;
    }

    if (httpStatus >= 200 && httpStatus < 300) {
        result = [body retain];
    } else {
        failure = [NSString stringWithFormat:@"HTTP %ld", (long)httpStatus];
    }

cleanup:
    mbedtls_net_free(&server);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_x509_crt_free(&cacert);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);

    if (!result && errorString) *errorString = failure ?: @"Unknown HTTPS error";
    return [result autorelease];
}
