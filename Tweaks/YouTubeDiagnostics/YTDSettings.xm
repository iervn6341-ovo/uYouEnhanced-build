#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <YouTubeHeader/YTIIcon.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import "YTDiagnosticsViewController.h"

static const NSInteger YouTubeDiagnosticsSection = 'ytdg';
static const NSInteger YouGroupSettingsSection = 'psyt';

static NSString *YTDSettingsText(NSString *traditionalChinese,
                                 NSString *english,
                                 NSString *japanese) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    if ([language hasPrefix:@"zh"]) return traditionalChinese;
    if ([language hasPrefix:@"ja"]) return japanese;
    return english;
}

static YTSettingsViewController *YTDSettingsControllerForManager(id manager) {
    NSArray<NSString *> *keys = @[@"_dataDelegate",
                                  @"_settingsViewControllerDelegate"];
    SEL modern =
        @selector(setSectionItems:forCategory:title:icon:titleDescription:
                  headerHidden:);
    SEL legacy =
        @selector(setSectionItems:forCategory:title:titleDescription:
                  headerHidden:);
    for (NSString *key in keys) {
        id candidate;
        @try {
            candidate = [manager valueForKey:key];
        } @catch (__unused NSException *exception) {
            candidate = nil;
        }
        if ([candidate isKindOfClass:UIViewController.class] &&
            ([candidate respondsToSelector:modern] ||
             [candidate respondsToSelector:legacy])) {
            return candidate;
        }
    }
    return nil;
}

@interface YTSettingsSectionItemManager (YouTubeDiagnostics)
- (void)ytd_updateDiagnosticsSectionWithEntry:(id)entry;
@end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
    NSArray<NSNumber *> *original = %orig;
    if ([original containsObject:@(YouTubeDiagnosticsSection)]) {
        return original;
    }
    NSMutableArray<NSNumber *> *order =
        original.mutableCopy ?: [NSMutableArray array];
    NSUInteger index = [order indexOfObject:@(1)];
    [order insertObject:@(YouTubeDiagnosticsSection)
                atIndex:index == NSNotFound ? order.count : index + 1];
    return order.copy;
}

%end

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategoriesForGroupType:(NSUInteger)type {
    NSArray<NSNumber *> *original = %orig;
    if (type != YouGroupSettingsSection ||
        [original containsObject:@(YouTubeDiagnosticsSection)]) {
        return original;
    }
    NSMutableArray<NSNumber *> *categories =
        original.mutableCopy ?: [NSMutableArray array];
    [categories addObject:@(YouTubeDiagnosticsSection)];
    return categories.copy;
}

- (NSArray<NSNumber *> *)orderedCategories {
    NSArray<NSNumber *> *original = %orig;
    if (self.type != 1 ||
        class_getClassMethod(objc_getClass("YTSettingsGroupData"),
                             @selector(tweaks)) ||
        [original containsObject:@(YouTubeDiagnosticsSection)]) {
        return original;
    }
    NSMutableArray<NSNumber *> *categories =
        original.mutableCopy ?: [NSMutableArray array];
    [categories insertObject:@(YouTubeDiagnosticsSection) atIndex:0];
    return categories.copy;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)ytd_updateDiagnosticsSectionWithEntry:(__unused id)entry {
    YTSettingsViewController *settingsViewController =
        YTDSettingsControllerForManager(self);
    if (!settingsViewController) return;

    YTSettingsSectionItem *openDiagnostics =
        [%c(YTSettingsSectionItem)
            itemWithTitle:YTDSettingsText(@"開啟 Universal Log",
                                          @"Open Universal Log",
                                          @"Universal Log を開く")
            titleDescription:YTDSettingsText(
                @"擷取、篩選、分享或清除 YouTube 的診斷記錄。",
                @"Capture, filter, share, or clear YouTube diagnostics.",
                @"YouTube の診断ログを取得、絞り込み、共有、消去します。")
            accessibilityIdentifier:@"YouTubeDiagnostics.Open"
            detailTextBlock:^NSString * {
                return YTDSettingsText(@"開啟", @"Open", @"開く");
            }
            selectBlock:^BOOL(__unused YTSettingsCell *cell,
                              __unused NSUInteger sectionItemIndex) {
                [settingsViewController
                    pushViewController:[YTDiagnosticsViewController new]];
                return YES;
            }];
    NSMutableArray<YTSettingsSectionItem *> *items =
        [NSMutableArray arrayWithObject:openDiagnostics];
    NSString *title =
        YTDSettingsText(@"YouTube 診斷記錄",
                        @"YouTube Diagnostics",
                        @"YouTube 診断ログ");
    NSString *description = YTDSettingsText(
        @"播放器錯誤、HUD、重試事件與目前程序的 Unified Log",
        @"Player errors, HUD messages, retry events, and current-process "
         "Unified Log",
        @"プレーヤーエラー、HUD、再試行イベント、現在のプロセスの "
         "Unified Log");

    if ([settingsViewController respondsToSelector:
            @selector(setSectionItems:forCategory:title:icon:
                      titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_SETTINGS;
        [settingsViewController
            setSectionItems:items
                forCategory:YouTubeDiagnosticsSection
                       title:title
                        icon:icon
            titleDescription:description
                headerHidden:NO];
    } else if ([settingsViewController respondsToSelector:
                   @selector(setSectionItems:forCategory:title:
                             titleDescription:headerHidden:)]) {
        [settingsViewController
            setSectionItems:items
                forCategory:YouTubeDiagnosticsSection
                       title:title
            titleDescription:description
                headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == YouTubeDiagnosticsSection) {
        [self ytd_updateDiagnosticsSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end
