#import "CICredentialStore.h"
#import <Security/Security.h>

static NSString *const CICredentialService = @"com.captionisland.lyricfind";
static NSString *const CIDisplayAPIKeyAccount = @"display-api-key";
static NSString *const CILRCKeyAccount = @"lrc-key";

static NSMutableDictionary *CIKeychainQuery(NSString *account) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CICredentialService,
        (__bridge id)kSecAttrAccount: account
    } mutableCopy];
}

static NSString *CIReadCredential(NSString *account) {
    NSMutableDictionary *query = CIKeychainQuery(account);
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return @"";
    NSData *data = CFBridgingRelease(result);
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return value ?: @"";
}

static BOOL CIWriteCredential(NSString *account, NSString *value) {
    NSMutableDictionary *query = CIKeychainQuery(account);
    if (value.length == 0) {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return status == errSecSuccess || status == errSecItemNotFound;
    }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)attributes);
    if (status != errSecItemNotFound) return status == errSecSuccess;
    query[(__bridge id)kSecValueData] = data;
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)query, NULL) == errSecSuccess;
}

NSString *CILyricFindDisplayAPIKey(void) {
    return CIReadCredential(CIDisplayAPIKeyAccount);
}

NSString *CILyricFindLRCKey(void) {
    return CIReadCredential(CILRCKeyAccount);
}

BOOL CISetLyricFindDisplayAPIKey(NSString *value) {
    return CIWriteCredential(CIDisplayAPIKeyAccount, value ?: @"");
}

BOOL CISetLyricFindLRCKey(NSString *value) {
    return CIWriteCredential(CILRCKeyAccount, value ?: @"");
}
