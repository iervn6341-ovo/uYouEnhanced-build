#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <YouTubeHeader/YTIIcon.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import "CICaptionCoordinator.h"
#import "CIConstants.h"
#import "CILogViewController.h"

static const NSInteger CaptionIslandSection = 'capi';
static const NSInteger YouGroupSettingsSection = 'psyt';

static void CIRefreshPushConfiguration(void) {
    Class bridge = NSClassFromString(@"CIActivityBridge");
    SEL selector =
        NSSelectorFromString(@"refreshPushConfiguration");
    if ([bridge respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(
            bridge,
            selector
        );
    }
}

static void CIStoreBool(NSString *key, BOOL value) {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
    if ([key isEqualToString:CIPushRelayEnabledKey]) {
        CIRefreshPushConfiguration();
    }
}

static void CIStoreInteger(NSString *key, NSInteger value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
}

static NSString *CILanguageTitle(NSString *code) {
    if ([code isEqualToString:@"en"]) return CILocalized(@"LANGUAGE_ENGLISH", @"English");
    if ([code isEqualToString:@"ja"]) return CILocalized(@"LANGUAGE_JAPANESE", @"Japanese");
    return CILocalized(@"LANGUAGE_TRADITIONAL_CHINESE", @"Traditional Chinese");
}

static NSString *CIDurationLimitTitle(NSInteger minutes) {
    if (minutes == 0) {
        return CILocalized(@"DURATION_UNLIMITED", @"No limit");
    }
    if (minutes == 1) {
        return CILocalized(@"DURATION_ONE_MINUTE", @"1 minute");
    }
    return [NSString stringWithFormat:
        CILocalized(@"DURATION_MINUTES_FORMAT", @"%ld minutes"),
        (long)minutes];
}

static NSString *CIPushRelayDetail(void) {
    if (!CIPreferenceBool(CIPushRelayEnabledKey, NO)) {
        return CILocalized(
            @"PUSH_RELAY_DISABLED",
            @"Off"
        );
    }
    if (!CIPushRelayConfigurationIsReady()) {
        return CILocalized(
            @"PUSH_RELAY_NEEDS_SETUP",
            @"Setup required"
        );
    }
    NSURL *URL = [NSURL URLWithString:
        CIPushRelayURLString()];
    return URL.host.length > 0
        ? URL.host
        : CILocalized(@"PUSH_RELAY_READY", @"Ready");
}

static BOOL CIPushRelayCredentialsAreReady(void) {
    NSString *token = CIPushRelayAccessToken();
    return CIPushRelayURLString().length > 0 &&
        [token lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 32;
}

static BOOL CIPushRelayHasSignerOwnedBundleID(void) {
    return ![NSBundle.mainBundle.bundleIdentifier
        isEqualToString:@"com.google.ios.youtube"];
}

static void CIPresentPushRelayError(
    UIViewController *controller,
    NSString *message
) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"PUSH_RELAY_ERROR",
            @"AOD Push Relay"
        )
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"OK", @"OK")
                  style:UIAlertActionStyleDefault
                handler:nil]];
    [controller presentViewController:alert
                             animated:YES
                           completion:nil];
}

static void CIPresentPushRelayErrorWhenReady(
    UIViewController *controller,
    NSString *message,
    NSUInteger attemptsRemaining
) {
    __weak UIViewController *weakController = controller;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(0.1 * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            UIViewController *strongController = weakController;
            if (!strongController) return;
            if (strongController.presentedViewController) {
                if (attemptsRemaining > 0) {
                    CIPresentPushRelayErrorWhenReady(
                        strongController,
                        message,
                        attemptsRemaining - 1
                    );
                }
                return;
            }
            if (strongController.viewIfLoaded.window) {
                CIPresentPushRelayError(
                    strongController,
                    message
                );
            }
        }
    );
}

static void CISchedulePushRelayError(
    UIViewController *controller,
    NSString *message
) {
    CIPresentPushRelayErrorWhenReady(
        controller,
        message,
        15
    );
}

static void CIPresentPushRelayConfiguration(
    YTSettingsViewController *settingsViewController,
    BOOL enableAfterSaving
) {
    NSString *configurationDescription = enableAfterSaving
        ? CILocalized(
            @"PUSH_RELAY_ENABLE_CONFIRMATION",
            @"Enter your HTTPS relay URL and access token. Saving enables caption timeline uploads to that relay; it sends the current and next line through Apple APNs. iOS may delay or throttle delivery."
        )
        : CILocalized(
            @"PUSH_RELAY_CONFIGURATION_DESCRIPTION",
            @"Store your HTTPS relay URL and access token. Saving here does not enable uploads; use the separate AOD remote updates switch."
        );
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"PUSH_RELAY_CONFIGURATION",
            @"AOD Push Relay"
        )
        message:configurationDescription
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:
        ^(UITextField *field) {
            field.placeholder = @"https://relay.example.com";
            field.text = [NSUserDefaults.standardUserDefaults
                stringForKey:CIPushRelayURLKey] ?: @"";
            field.keyboardType =
                UIKeyboardTypeURL;
            field.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            field.autocorrectionType =
                UITextAutocorrectionTypeNo;
        }];
    [alert addTextFieldWithConfigurationHandler:
        ^(UITextField *field) {
            field.placeholder =
                CIPushRelayAccessToken().length > 0
                    ? CILocalized(
                        @"PUSH_RELAY_TOKEN_STORED",
                        @"Access token stored; leave blank to keep it"
                    )
                    : CILocalized(
                        @"PUSH_RELAY_TOKEN",
                        @"Relay access token"
                    );
            field.secureTextEntry = YES;
            field.autocapitalizationType =
                UITextAutocapitalizationTypeNone;
            field.autocorrectionType =
                UITextAutocorrectionTypeNo;
        }];
    __weak UIAlertController *weakAlert = alert;
    __weak YTSettingsViewController *weakSettingsViewController =
        settingsViewController;
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
                  style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *action) {
                    if (!enableAfterSaving) return;
                    YTSettingsViewController *strongSettingsViewController =
                        weakSettingsViewController;
                    CIStoreBool(CIPushRelayEnabledKey, NO);
                    [strongSettingsViewController reloadData];
                }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(
            @"PUSH_RELAY_CLEAR",
            @"Clear"
        )
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *action) {
                    YTSettingsViewController *strongSettingsViewController =
                        weakSettingsViewController;
                    if (!CISetPushRelayAccessToken(nil)) {
                        CISchedulePushRelayError(
                            strongSettingsViewController,
                            CILocalized(
                                @"PUSH_RELAY_KEYCHAIN_CLEAR_FAILED",
                                @"The stored access token could not be removed from Keychain."
                            )
                        );
                        return;
                    }
                    [NSUserDefaults.standardUserDefaults
                        removeObjectForKey:CIPushRelayURLKey];
                    [NSUserDefaults.standardUserDefaults
                        setBool:NO
                         forKey:CIPushRelayEnabledKey];
                    [CICaptionCoordinator.sharedCoordinator
                        reloadPreferences];
                    CIRefreshPushConfiguration();
                    [strongSettingsViewController reloadData];
                }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(
            @"PUSH_RELAY_SAVE",
            @"Save"
        )
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    UIAlertController *strongAlert = weakAlert;
                    YTSettingsViewController *strongSettingsViewController =
                        weakSettingsViewController;
                    if (!strongAlert ||
                        !strongSettingsViewController) {
                        return;
                    }
                    NSString *URLString =
                        [strongAlert.textFields.firstObject.text
                            stringByTrimmingCharactersInSet:
                                NSCharacterSet
                                    .whitespaceAndNewlineCharacterSet];
                    NSURLComponents *components =
                        [NSURLComponents
                            componentsWithString:URLString];
                    BOOL valid =
                        [components.scheme.lowercaseString
                            isEqualToString:@"https"] &&
                        components.host.length > 0 &&
                        components.user.length == 0 &&
                        components.password.length == 0 &&
                        components.query.length == 0 &&
                        components.fragment.length == 0;
                    if (!valid) {
                        CISchedulePushRelayError(
                            strongSettingsViewController,
                            CILocalized(
                                @"PUSH_RELAY_HTTPS_REQUIRED",
                                @"Use an HTTPS URL without credentials, query parameters, or fragments."
                            )
                        );
                        return;
                    }
                    NSString *newToken =
                        [(strongAlert.textFields.lastObject.text ?: @"")
                            stringByTrimmingCharactersInSet:
                                NSCharacterSet
                                    .whitespaceAndNewlineCharacterSet];
                    if (newToken.length > 0 &&
                        [newToken lengthOfBytesUsingEncoding:
                            NSUTF8StringEncoding] < 32) {
                        CISchedulePushRelayError(
                            strongSettingsViewController,
                            CILocalized(
                                @"PUSH_RELAY_TOKEN_TOO_SHORT",
                                @"Use a relay access token containing at least 32 bytes."
                            )
                        );
                        return;
                    }
                    if (newToken.length > 0 &&
                        !CISetPushRelayAccessToken(newToken)) {
                        CISchedulePushRelayError(
                            strongSettingsViewController,
                            CILocalized(
                                @"PUSH_RELAY_KEYCHAIN_FAILED",
                                @"The access token could not be saved to Keychain."
                            )
                        );
                        return;
                    }
                    if (newToken.length == 0) {
                        NSString *storedToken =
                            CIPushRelayAccessToken();
                        NSUInteger storedTokenBytes =
                            [storedToken lengthOfBytesUsingEncoding:
                                NSUTF8StringEncoding];
                        if (storedTokenBytes == 0) {
                            CISchedulePushRelayError(
                                strongSettingsViewController,
                                CILocalized(
                                    @"PUSH_RELAY_TOKEN_REQUIRED",
                                    @"Enter the relay access token."
                                )
                            );
                            return;
                        }
                        if (storedTokenBytes < 32) {
                            CISchedulePushRelayError(
                                strongSettingsViewController,
                                CILocalized(
                                    @"PUSH_RELAY_TOKEN_TOO_SHORT",
                                    @"Use a relay access token containing at least 32 bytes."
                                )
                            );
                            return;
                        }
                    }
                    [NSUserDefaults.standardUserDefaults
                        setObject:URLString
                           forKey:CIPushRelayURLKey];
                    BOOL bundleIDIsEligible =
                        CIPushRelayHasSignerOwnedBundleID();
                    if (enableAfterSaving &&
                        bundleIDIsEligible) {
                        [NSUserDefaults.standardUserDefaults
                            setBool:YES
                             forKey:CIPushRelayEnabledKey];
                    } else if (!bundleIDIsEligible) {
                        [NSUserDefaults.standardUserDefaults
                            setBool:NO
                             forKey:CIPushRelayEnabledKey];
                    }
                    [CICaptionCoordinator.sharedCoordinator
                        reloadPreferences];
                    CIRefreshPushConfiguration();
                    [strongSettingsViewController reloadData];
                    if (!bundleIDIsEligible) {
                        CISchedulePushRelayError(
                            strongSettingsViewController,
                            CILocalized(
                                @"PUSH_RELAY_CUSTOM_APP_ID_REQUIRED",
                                @"AOD push cannot use Google's com.google.ios.youtube identifier. Sign with an explicit App ID owned by your Apple Developer Team. The relay settings were saved, but remote updates remain off."
                            )
                        );
                    }
                }]];
    [settingsViewController
        presentViewController:alert
                     animated:YES
                   completion:nil];
}

static YTSettingsViewController *CISettingsControllerForManager(id manager) {
    NSArray<NSString *> *keys = @[@"_dataDelegate", @"_settingsViewControllerDelegate"];
    SEL modern = @selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:);
    SEL legacy = @selector(setSectionItems:forCategory:title:titleDescription:headerHidden:);
    for (NSString *key in keys) {
        id candidate;
        @try { candidate = [manager valueForKey:key]; }
        @catch (__unused NSException *exception) { candidate = nil; }
        if ([candidate isKindOfClass:UIViewController.class] &&
            ([candidate respondsToSelector:modern] || [candidate respondsToSelector:legacy])) {
            return candidate;
        }
    }
    return nil;
}

@interface YTSettingsSectionItemManager (CaptionIsland)
- (void)ci_updateCaptionIslandSectionWithEntry:(id)entry;
@end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
    NSArray<NSNumber *> *original = %orig;
    if ([original containsObject:@(CaptionIslandSection)]) return original;
    NSMutableArray<NSNumber *> *order = original.mutableCopy;
    NSUInteger index = [order indexOfObject:@(1)];
    [order insertObject:@(CaptionIslandSection) atIndex:index == NSNotFound ? order.count : index + 1];
    return order.copy;
}

%end

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategoriesForGroupType:(NSUInteger)type {
    NSArray<NSNumber *> *original = %orig;
    if (type != YouGroupSettingsSection || [original containsObject:@(CaptionIslandSection)]) return original;
    NSMutableArray<NSNumber *> *categories = original.mutableCopy ?: [NSMutableArray array];
    [categories addObject:@(CaptionIslandSection)];
    return categories.copy;
}

- (NSArray<NSNumber *> *)orderedCategories {
    NSArray<NSNumber *> *original = %orig;
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)) ||
        [original containsObject:@(CaptionIslandSection)]) return original;
    NSMutableArray<NSNumber *> *categories = original.mutableCopy ?: [NSMutableArray array];
    [categories insertObject:@(CaptionIslandSection) atIndex:0];
    return categories.copy;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)ci_updateCaptionIslandSectionWithEntry:(__unused id)entry {
    YTSettingsViewController *settingsViewController = CISettingsControllerForManager(self);
    if (!settingsViewController) return;

    NSMutableArray<YTSettingsSectionItem *> *items = [NSMutableArray array];
    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(@"ENABLED", @"Enable Live Activity")
        titleDescription:CILocalized(@"ENABLED_DESCRIPTION", @"Show synchronized captions and lyrics in the system Dynamic Island and on the Lock Screen.")
        accessibilityIdentifier:@"CaptionIsland.Enabled"
        switchOn:CIPreferenceBool(CIEnabledKey, YES)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            CIStoreBool(CIEnabledKey, enabled);
            return YES;
        } settingItemId:0]];

    NSString *languageTitle = CILocalized(@"PREFERRED_LANGUAGE", @"Preferred caption language");
    NSArray<NSString *> *languageCodes = @[@"zh-Hant", @"en", @"ja"];
    YTSettingsSectionItem *language = [%c(YTSettingsSectionItem)
        itemWithTitle:languageTitle
        titleDescription:CILocalized(@"PREFERRED_LANGUAGE_DESCRIPTION", @"Only original manual CC is selected; auto-translation is never requested.")
        accessibilityIdentifier:@"CaptionIsland.Language"
        detailTextBlock:^NSString *{ return CILanguageTitle(CIPreferredLanguage()); }
        selectBlock:^BOOL(__unused YTSettingsCell *cell, __unused NSUInteger sectionItemIndex) {
            NSMutableArray<YTSettingsSectionItem *> *rows = [NSMutableArray array];
            for (NSString *code in languageCodes) {
                [rows addObject:[%c(YTSettingsSectionItem) checkmarkItemWithTitle:CILanguageTitle(code)
                    selectBlock:^BOOL(__unused YTSettingsCell *pickerCell,
                                      __unused NSUInteger pickerIndex) {
                        [NSUserDefaults.standardUserDefaults setObject:code forKey:CIPreferredLanguageKey];
                        [CICaptionCoordinator.sharedCoordinator reloadPreferences];
                        [settingsViewController reloadData];
                        return YES;
                    }]];
            }
            NSUInteger selected = [languageCodes indexOfObject:CIPreferredLanguage()];
            if (selected == NSNotFound) selected = 0;
            YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                initWithNavTitle:languageTitle pickerSectionTitle:nil rows:rows
                selectedItemIndex:selected parentResponder:[settingsViewController parentResponder]];
            [settingsViewController pushViewController:picker];
            return YES;
        }];
    [items addObject:language];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(@"DISABLE_FOR_SHORTS", @"Disable for Shorts")
        titleDescription:CILocalized(@"DISABLE_FOR_SHORTS_DESCRIPTION", @"Do not start a Live Activity or search for lyrics while watching Shorts.")
        accessibilityIdentifier:@"CaptionIsland.DisableForShorts"
        switchOn:CIPreferenceBool(CIDisableForShortsKey, YES)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            CIStoreBool(CIDisableForShortsKey, enabled);
            return YES;
        } settingItemId:0]];

    NSString *durationLimitTitle =
        CILocalized(@"MAXIMUM_VIDEO_DURATION", @"Maximum video duration");
    NSArray<NSNumber *> *durationChoices =
        @[@1, @3, @5, @10, @15, @30, @60, @0];
    YTSettingsSectionItem *durationLimit = [%c(YTSettingsSectionItem)
        itemWithTitle:durationLimitTitle
        titleDescription:CILocalized(@"MAXIMUM_VIDEO_DURATION_DESCRIPTION", @"Caption Island stays off when a video is longer than this limit.")
        accessibilityIdentifier:@"CaptionIsland.MaximumVideoDuration"
        detailTextBlock:^NSString * {
            return CIDurationLimitTitle(CIMaximumVideoDurationMinutes());
        }
        selectBlock:^BOOL(__unused YTSettingsCell *cell,
                          __unused NSUInteger sectionItemIndex) {
            NSMutableArray<YTSettingsSectionItem *> *rows =
                [NSMutableArray arrayWithCapacity:durationChoices.count];
            for (NSNumber *choice in durationChoices) {
                [rows addObject:[%c(YTSettingsSectionItem)
                    checkmarkItemWithTitle:
                        CIDurationLimitTitle(choice.integerValue)
                    selectBlock:^BOOL(
                        __unused YTSettingsCell *pickerCell,
                        __unused NSUInteger pickerIndex
                    ) {
                        CIStoreInteger(
                            CIMaximumVideoDurationMinutesKey,
                            choice.integerValue
                        );
                        [settingsViewController reloadData];
                        return YES;
                    }]];
            }
            NSUInteger selected = [durationChoices indexOfObject:
                @(CIMaximumVideoDurationMinutes())];
            if (selected == NSNotFound) selected = 2;
            YTSettingsPickerViewController *picker =
                [[%c(YTSettingsPickerViewController) alloc]
                    initWithNavTitle:durationLimitTitle
                    pickerSectionTitle:nil
                    rows:rows
                    selectedItemIndex:selected
                    parentResponder:
                        [settingsViewController parentResponder]];
            [settingsViewController pushViewController:picker];
            return YES;
        }];
    [items addObject:durationLimit];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(
            @"AOD_REMOTE_PUSH",
            @"AOD remote updates"
        )
        titleDescription:CILocalized(
            @"AOD_REMOTE_PUSH_DESCRIPTION",
            @"Upload the selected timeline and playback metadata to your HTTPS relay. The relay sends current and next lines through Apple APNs; iOS may delay or throttle delivery and AOD refreshes."
        )
        accessibilityIdentifier:@"CaptionIsland.PushRelayEnabled"
        switchOn:CIPreferenceBool(CIPushRelayEnabledKey, NO)
        switchBlock:^BOOL(
            __unused YTSettingsCell *cell,
            BOOL enabled
        ) {
            if (!enabled) {
                CIStoreBool(CIPushRelayEnabledKey, NO);
            } else if (!CIPushRelayHasSignerOwnedBundleID()) {
                CIStoreBool(CIPushRelayEnabledKey, NO);
                CISchedulePushRelayError(
                    settingsViewController,
                    CILocalized(
                        @"PUSH_RELAY_CUSTOM_APP_ID_REQUIRED",
                        @"AOD push cannot use Google's com.google.ios.youtube identifier. Sign with an explicit App ID owned by your Apple Developer Team. Relay settings can still be saved, but remote updates remain off."
                    )
                );
            } else if (CIPushRelayCredentialsAreReady()) {
                CIStoreBool(CIPushRelayEnabledKey, YES);
            } else {
                CIStoreBool(CIPushRelayEnabledKey, NO);
                CIPresentPushRelayConfiguration(
                    settingsViewController,
                    YES
                );
            }
            [settingsViewController reloadData];
            return YES;
        } settingItemId:0]];

    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:CILocalized(
            @"PUSH_RELAY_CONFIGURATION",
            @"AOD Push Relay"
        )
        titleDescription:CILocalized(
            @"PUSH_RELAY_CONFIGURATION_DESCRIPTION",
            @"Store your HTTPS relay URL and access token. Saving here does not enable uploads; use the separate AOD remote updates switch."
        )
        accessibilityIdentifier:@"CaptionIsland.PushRelayConfiguration"
        detailTextBlock:^NSString * {
            return CIPushRelayDetail();
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            CIPresentPushRelayConfiguration(
                settingsViewController,
                NO
            );
            return YES;
        }]];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(@"EXTERNAL_LYRICS", @"LRCLIB lyrics")
        titleDescription:CILocalized(@"EXTERNAL_LYRICS_DESCRIPTION", @"Look for synchronized LRCLIB lyrics before YouTube captions.")
        accessibilityIdentifier:@"CaptionIsland.ExternalLyrics"
        switchOn:CIPreferenceBool(CIExternalLyricsEnabledKey, YES)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            CIStoreBool(CIExternalLyricsEnabledKey, enabled);
            return YES;
        } settingItemId:0]];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(@"SOURCE_BADGE", @"Show source badge")
        titleDescription:CILocalized(@"SOURCE_BADGE_DESCRIPTION", @"Display CC or ASR beside the current line. LRCLIB is always identified.")
        accessibilityIdentifier:@"CaptionIsland.SourceBadge"
        switchOn:CIPreferenceBool(CIShowSourceBadgeKey, YES)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            CIStoreBool(CIShowSourceBadgeKey, enabled);
            return YES;
        } settingItemId:0]];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(@"DEBUG_LOGGING", @"Detailed logging")
        titleDescription:CILocalized(@"DEBUG_LOGGING_DESCRIPTION", @"Include detailed diagnostics. Lyrics, URLs, cookies, and authorization data are never recorded.")
        accessibilityIdentifier:@"CaptionIsland.Debug"
        switchOn:CIPreferenceBool(CIDebugLoggingKey, NO)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            [NSUserDefaults.standardUserDefaults setBool:enabled forKey:CIDebugLoggingKey];
            return YES;
        } settingItemId:0]];

    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:CILocalized(@"LOG_PREVIEW", @"Log Preview")
        titleDescription:CILocalized(@"LOG_PREVIEW_DESCRIPTION", @"Review, filter, share, or clear Caption Island diagnostics.")
        accessibilityIdentifier:@"CaptionIsland.LogPreview"
        detailTextBlock:^NSString * {
            return CILocalized(@"LOG_PREVIEW_DETAIL", @"Open");
        }
        selectBlock:^BOOL(__unused YTSettingsCell *cell,
                          __unused NSUInteger sectionItemIndex) {
            CILogViewController *controller = [CILogViewController new];
            [settingsViewController pushViewController:controller];
            return YES;
        }]];

    if ([settingsViewController respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_SETTINGS;
        [settingsViewController setSectionItems:items forCategory:CaptionIslandSection
            title:CILocalized(@"SETTINGS_TITLE", @"Caption Island") icon:icon
            titleDescription:CILocalized(@"SETTINGS_DESCRIPTION", @"LRCLIB → manual CC → YouTube ASR") headerHidden:NO];
    } else if ([settingsViewController respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
        [settingsViewController setSectionItems:items forCategory:CaptionIslandSection
            title:CILocalized(@"SETTINGS_TITLE", @"Caption Island")
            titleDescription:CILocalized(@"SETTINGS_DESCRIPTION", @"LRCLIB → manual CC → YouTube ASR") headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == CaptionIslandSection) {
        [self ci_updateCaptionIslandSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end
