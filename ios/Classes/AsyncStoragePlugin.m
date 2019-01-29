#import "AsyncStoragePlugin.h"
#import <Foundation/Foundation.h>

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#define RCTNullIfNil(value) (value ?: (id)kCFNull)

static NSString *const RCTStorageDirectory = @"RCTAsyncLocalStorage_V1";
static NSString *const RCTManifestFileName = @"manifest.json";
static NSString *const CHANNEL_NAME = @"datanor.ee/async_storage";

#pragma mark - Static helper functions


NSString *RCTMD5Hash(NSString *string)
{
    const char *str = string.UTF8String;
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), result);
    
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
}

NSDictionary<NSString *, id> *RCTMakeError(NSString *message,
                                           id __nullable toStringify,
                                           NSDictionary<NSString *, id> *__nullable extraData)
{
    if (toStringify) {
        message = [message stringByAppendingString:[toStringify description]];
    }
    
    NSMutableDictionary<NSString *, id> *error = [extraData mutableCopy] ?: [NSMutableDictionary new];
    error[@"message"] = message;
    return error;
}

NSDictionary<NSString *, id> *RCTMakeAndLogError(NSString *message,
                                                 id __nullable toStringify,
                                                 NSDictionary<NSString *, id> *__nullable extraData)
{
    NSDictionary<NSString *, id> *error = RCTMakeError(message, toStringify, extraData);
    NSLog(@"\nError: %@", error);
    return error;
}







static NSString *RCTReadFile(NSString *filePath, NSString *key, NSDictionary **errorOut)
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSError *error;
        NSStringEncoding encoding;
        NSString *entryString = [NSString stringWithContentsOfFile:filePath usedEncoding:&encoding error:&error];
        NSDictionary *extraData = @{@"key": RCTNullIfNil(key)};
        
        if (error) {
            if (errorOut) *errorOut = RCTMakeError(@"Failed to read storage file.", error, extraData);
            return nil;
        }
        
        if (encoding != NSUTF8StringEncoding) {
            if (errorOut) *errorOut = RCTMakeError(@"Incorrect encoding of storage file: ", @(encoding), extraData);
            return nil;
        }
        return entryString;
    }
    
    return nil;
}

static NSString *RCTGetStorageDirectory()
{
    static NSString *storageDirectory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if TARGET_OS_TV
        storageDirectory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
#else
        storageDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
#endif
        storageDirectory = [storageDirectory stringByAppendingPathComponent:RCTStorageDirectory];
    });
    return storageDirectory;
}

static NSString *RCTGetManifestFilePath()
{
    static NSString *manifestFilePath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manifestFilePath = [RCTGetStorageDirectory() stringByAppendingPathComponent:RCTManifestFileName];
    });
    return manifestFilePath;
}



static NSCache *RCTGetCache()
{
    // We want all instances to share the same cache since they will be reading/writing the same files.
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.totalCostLimit = 2 * 1024 * 1024; // 2MB
        
        // Clear cache in the event of a memory warning
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            [cache removeAllObjects];
        }];
    });
    return cache;
}

static BOOL RCTHasCreatedStorageDirectory = NO;
static NSDictionary *RCTDeleteStorageDirectory()
{
    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:RCTGetStorageDirectory() error:&error];
    RCTHasCreatedStorageDirectory = NO;
    return error ? RCTMakeError(@"Failed to delete storage directory.", error, nil) : nil;
}

NSError *RCTErrorWithMessage(NSString *message)
{
    NSDictionary<NSString *, id> *errorInfo = @{NSLocalizedDescriptionKey: message};
    return [[NSError alloc] initWithDomain:@"com.yourcompany.appname" code:0 userInfo:errorInfo];
}

static id __nullable _RCTJSONParse(NSString *__nullable jsonString, BOOL mutable, NSError **error)
{
    static SEL JSONKitSelector = NULL;
    static SEL JSONKitMutableSelector = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL selector = NSSelectorFromString(@"objectFromJSONStringWithParseOptions:error:");
        if ([NSString instancesRespondToSelector:selector]) {
            JSONKitSelector = selector;
            JSONKitMutableSelector = NSSelectorFromString(@"mutableObjectFromJSONStringWithParseOptions:error:");
        }
    });
    
    if (jsonString) {
        
        // Use JSONKit if available and string is not a fragment
        if (JSONKitSelector) {
            NSInteger length = jsonString.length;
            for (NSInteger i = 0; i < length; i++) {
                unichar c = [jsonString characterAtIndex:i];
                if (strchr("{[", c)) {
                    static const int options = (1 << 2); // loose unicode
                    SEL selector = mutable ? JSONKitMutableSelector : JSONKitSelector;
                    return ((id (*)(id, SEL, int, NSError **))objc_msgSend)(jsonString, selector, options, error);
                }
                if (!strchr(" \r\n\t", c)) {
                    break;
                }
            }
        }
        
        // Use Foundation JSON method
        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) {
            jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
            if (jsonData) {
                NSLog(@"RCTJSONParse received the following string, which could "
                           "not be losslessly converted to UTF8 data: '%@'", jsonString);
            } else {
                NSString *errorMessage = @"RCTJSONParse received invalid UTF8 data";
                if (error) {
                    *error = RCTErrorWithMessage(errorMessage);
                } else {
                    NSLog(@"%@", errorMessage);
                }
                return nil;
            }
        }
        NSJSONReadingOptions options = NSJSONReadingAllowFragments;
        if (mutable) {
            options |= NSJSONReadingMutableContainers;
        }
        return [NSJSONSerialization JSONObjectWithData:jsonData
                                               options:options
                                                 error:error];
    }
    return nil;
}



id __nullable RCTJSONParseMutable(NSString *__nullable jsonString, NSError **error)
{
    return _RCTJSONParse(jsonString, YES, error);
}

#pragma mark - RCTAsyncLocalStorage

@implementation AsyncStoragePlugin

BOOL _haveSetup;
NSMutableDictionary<NSString *, NSString *> *_manifest;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:CHANNEL_NAME
            binaryMessenger:[registrar messenger]];
  AsyncStoragePlugin* instance = [[AsyncStoragePlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}



- (NSDictionary *)_ensureSetup
{
    
    
    NSError *error = nil;
    if (!RCTHasCreatedStorageDirectory) {
        [[NSFileManager defaultManager] createDirectoryAtPath:RCTGetStorageDirectory()
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        if (error) {
            return RCTMakeError(@"Failed to create storage directory.", error, nil);
        }
        RCTHasCreatedStorageDirectory = YES;
    }
    if (!_haveSetup) {
        NSDictionary *errorOut;
        NSString *serialized = RCTReadFile(RCTGetManifestFilePath(), RCTManifestFileName, &errorOut);
        _manifest = serialized ? RCTJSONParseMutable(serialized, &error) : [NSMutableDictionary new];
        if (error) {
            NSLog(@"Failed to parse manifest - creating new one.\n\n%@", error);
            _manifest = [NSMutableDictionary new];
        }
        _haveSetup = YES;
    }
    return nil;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"multiGet" isEqualToString:call.method]) {
      NSDictionary *errorOut = [self _ensureSetup];
      if (errorOut) {
          return;
      }
      NSArray *argsMap = call.arguments;
      NSMutableDictionary *keyValuePairs = [NSMutableDictionary dictionary];
      for(id key in argsMap) {
          id keyError;
          id value = [self _getValueForKey:key errorOut:&keyError];
          [keyValuePairs setObject:RCTNullIfNil(value) forKey:key];
      }
    result(keyValuePairs);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (NSString *)_getValueForKey:(NSString *)key errorOut:(NSDictionary **)errorOut
{
    NSString *value = _manifest[key]; // nil means missing, null means there may be a data file, else: NSString
    if (value == (id)kCFNull) {
        value = [RCTGetCache() objectForKey:key];
        if (!value) {
            NSString *filePath = [self _filePathForKey:key];
            value = RCTReadFile(filePath, key, errorOut);
            if (value) {
                [RCTGetCache() setObject:value forKey:key cost:value.length];
            } else {
                // file does not exist after all, so remove from manifest (no need to save
                // manifest immediately though, as cost of checking again next time is negligible)
                [_manifest removeObjectForKey:key];
            }
        }
    }
    return value;
}

- (NSString *)_filePathForKey:(NSString *)key
{
    NSString *safeFileName = RCTMD5Hash(key);
    return [RCTGetStorageDirectory() stringByAppendingPathComponent:safeFileName];
}



@end
