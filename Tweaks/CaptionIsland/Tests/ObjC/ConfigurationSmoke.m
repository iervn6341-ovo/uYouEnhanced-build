#import <Foundation/Foundation.h>
#import "../../CIConstants.h"

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"Configuration smoke failed: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults =
            NSUserDefaults.standardUserDefaults;
        id previousPriorities =
            [defaults objectForKey:CICaptionLanguagePrioritiesKey];
        id previousLegacy =
            [defaults objectForKey:CIPreferredLanguageKey];

        [defaults removeObjectForKey:
            CICaptionLanguagePrioritiesKey];
        [defaults setObject:@"ja"
                     forKey:CIPreferredLanguageKey];
        CIAssert([CICaptionLanguagePriorities()
            isEqualToArray:@[@"ja", @"zh-Hant", @"en"]],
            @"the old single-language preference should migrate to the front");

        CISetCaptionLanguagePriorities(@[
            @"en_GB", @"ja", @"JA", @"bad code", @"zh-Hant"
        ]);
        CIAssert([CICaptionLanguagePriorities()
            isEqualToArray:@[@"en-GB", @"ja", @"zh-Hant"]],
            @"language priorities should normalize, de-duplicate, and reject malformed codes");
        CIAssert([CIPreferredLanguage()
            isEqualToString:@"en-GB"],
            @"the compatibility language should remain the first priority");

        CISetCaptionLanguagePriorities(@[]);
        CIAssert([CICaptionLanguagePriorities()
            isEqualToArray:@[@"zh-Hant", @"en", @"ja"]],
            @"reset should restore the default language order");

        if (previousPriorities) {
            [defaults setObject:previousPriorities
                         forKey:CICaptionLanguagePrioritiesKey];
        } else {
            [defaults removeObjectForKey:
                CICaptionLanguagePrioritiesKey];
        }
        if (previousLegacy) {
            [defaults setObject:previousLegacy
                         forKey:CIPreferredLanguageKey];
        } else {
            [defaults removeObjectForKey:CIPreferredLanguageKey];
        }
        NSLog(@"Configuration smoke passed");
    }
    return 0;
}
