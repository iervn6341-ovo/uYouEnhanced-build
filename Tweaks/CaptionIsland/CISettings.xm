#import <UIKit/UIKit.h>
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

static void CIStoreBool(NSString *key, BOOL value) {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
}

static NSString *CILanguageTitle(NSString *code) {
    if ([code isEqualToString:@"en"]) return CILocalized(@"LANGUAGE_ENGLISH", @"English");
    if ([code isEqualToString:@"ja"]) return CILocalized(@"LANGUAGE_JAPANESE", @"Japanese");
    return CILocalized(@"LANGUAGE_TRADITIONAL_CHINESE", @"Traditional Chinese");
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
