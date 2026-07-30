#import "CIConstants.h"
#import "CILogStore.h"
#import <Security/Security.h>

NSString *const CIEnabledKey = @"CaptionIsland.Enabled";
NSString *const CIExternalLyricsEnabledKey = @"CaptionIsland.ExternalLyricsEnabled";
NSString *const CIShowSourceBadgeKey = @"CaptionIsland.ShowSourceBadge";
NSString *const CIPreferredLanguageKey = @"CaptionIsland.PreferredLanguage";
NSString *const CIDebugLoggingKey = @"CaptionIsland.DebugLogging";
NSString *const CIDisableForShortsKey = @"CaptionIsland.DisableForShorts";
NSString *const CIMaximumVideoDurationMinutesKey =
    @"CaptionIsland.MaximumVideoDurationMinutes";
NSString *const CIPushRelayEnabledKey =
    @"CaptionIsland.PushRelayEnabled";
NSString *const CIPushRelayURLKey =
    @"CaptionIsland.PushRelayURL";

BOOL CIPreferenceBool(NSString *key, BOOL defaultValue) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : defaultValue;
}

NSInteger CIPreferenceInteger(NSString *key, NSInteger defaultValue) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key]
        ? [defaults integerForKey:key]
        : defaultValue;
}

NSInteger CIMaximumVideoDurationMinutes(void) {
    NSInteger value =
        CIPreferenceInteger(CIMaximumVideoDurationMinutesKey, 5);
    if (value == 0) return 0;
    return value > 0 && value <= 180 ? value : 5;
}

static NSString *CIPushRelayKeychainService(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    return [NSString stringWithFormat:@"%@.CaptionIslandPushRelay",
        bundleID.length > 0 ? bundleID : @"CaptionIsland"];
}

static NSDictionary *CIPushRelayKeychainQuery(void) {
    return @{
        (__bridge id)kSecClass:
            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:
            CIPushRelayKeychainService(),
        (__bridge id)kSecAttrAccount:
            @"relay-access-token",
    };
}

NSString *CIPushRelayURLString(void) {
    NSString *raw = [NSUserDefaults.standardUserDefaults
        stringForKey:CIPushRelayURLKey] ?: @"";
    NSURLComponents *components =
        [NSURLComponents componentsWithString:raw];
    BOOL valid =
        [components.scheme.lowercaseString isEqualToString:@"https"] &&
        components.host.length > 0 &&
        components.user.length == 0 &&
        components.password.length == 0 &&
        components.query.length == 0 &&
        components.fragment.length == 0;
    return valid ? raw : @"";
}

NSString *CIPushRelayAccessToken(void) {
    NSMutableDictionary *query =
        [CIPushRelayKeychainQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] =
        (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching(
        (__bridge CFDictionaryRef)query,
        &result
    );
    if (status != errSecSuccess || !result) return @"";
    NSData *data = CFBridgingRelease(result);
    NSString *token = [[NSString alloc]
        initWithData:data
            encoding:NSUTF8StringEncoding];
    return token ?: @"";
}

BOOL CISetPushRelayAccessToken(NSString *token) {
    NSDictionary *query = CIPushRelayKeychainQuery();
    if (token.length == 0) {
        OSStatus deleteStatus = SecItemDelete(
            (__bridge CFDictionaryRef)query
        );
        return deleteStatus == errSecSuccess ||
            deleteStatus == errSecItemNotFound;
    }

    NSData *tokenData =
        [token dataUsingEncoding:NSUTF8StringEncoding];
    if (tokenData.length == 0) return NO;
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: tokenData,
        (__bridge id)kSecAttrAccessible:
        (__bridge id)
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus updateStatus = SecItemUpdate(
        (__bridge CFDictionaryRef)query,
        (__bridge CFDictionaryRef)attributes
    );
    if (updateStatus == errSecSuccess) return YES;
    if (updateStatus != errSecItemNotFound) return NO;

    NSMutableDictionary *newItem = [query mutableCopy];
    [newItem addEntriesFromDictionary:attributes];
    return SecItemAdd(
        (__bridge CFDictionaryRef)newItem,
        NULL
    ) == errSecSuccess;
}

BOOL CIPushRelayConfigurationIsReady(void) {
    NSString *token = CIPushRelayAccessToken();
    return CIPreferenceBool(CIPushRelayEnabledKey, NO) &&
        CIPushRelayURLString().length > 0 &&
        [token lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 32;
}

NSString *CIPreferredLanguage(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:CIPreferredLanguageKey];
    return value.length > 0 ? value : @"zh-Hant";
}

NSBundle *CIBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"CaptionIsland" ofType:@"bundle"];
        if (path.length > 0) bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}

NSString *CILocalized(NSString *key, NSString *fallback) {
    NSBundle *bundle = CIBundle();
    return bundle ? [bundle localizedStringForKey:key value:fallback table:nil] : fallback;
}

void CIDebugLog(NSString *format, ...) {
    if (!CIPreferenceBool(CIDebugLoggingKey, NO) || format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [CILogStore.sharedStore recordLevel:CILogLevelDebug
                               category:@"Pipeline"
                                message:message ?: @""];
}
