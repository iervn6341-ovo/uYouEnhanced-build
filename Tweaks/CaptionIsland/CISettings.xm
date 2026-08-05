#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <YouTubeHeader/YTIIcon.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import "CICaptionCoordinator.h"
#import "CIBackgroundPlaybackMonitor.h"
#import "CIConstants.h"
#import "CILanguagePriorityViewController.h"
#import "CILRCLIBCacheViewController.h"
#import "CILRCLIBProvider.h"
#import "CILogViewController.h"
#import "CIProcessDiagnostics.h"
#import "CITextUtilities.h"
#import "CIToastPresenter.h"
#import "CIVideoOverrides.h"
#import <math.h>

static const NSInteger CaptionIslandSection = 'capi';
static const NSInteger YouGroupSettingsSection = 'psyt';

static void CIStoreBool(NSString *key, BOOL value) {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
}

static void CIStoreInteger(NSString *key, NSInteger value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
    [CICaptionCoordinator.sharedCoordinator reloadPreferences];
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

static NSString *CISourcePriorityTitle(CISourcePriorityMode mode) {
    if (mode == CISourcePriorityYouTubeFirst) {
        return CILocalized(
            @"SOURCE_PRIORITY_YOUTUBE",
            @"YouTube captions first"
        );
    }
    return CILocalized(
        @"SOURCE_PRIORITY_LRCLIB",
        @"LRCLIB first"
    );
}

static NSString *CISourcePriorityDescription(void) {
    if (CISourcePriority() == CISourcePriorityYouTubeFirst) {
        return CILocalized(
            @"SETTINGS_DESCRIPTION_YOUTUBE_FIRST",
            @"Manual CC → YouTube ASR → LRCLIB"
        );
    }
    return CILocalized(
        @"SETTINGS_DESCRIPTION",
        @"LRCLIB → manual CC → YouTube ASR"
    );
}

static NSString *CIReturnHomeModeTitle(CIReturnHomeMode mode) {
    if (mode == CIReturnHomeModeCaptionIsland) {
        return CILocalized(
            @"RETURN_HOME_MODE_CAPTION_ISLAND",
            @"Caption Island (background captions)"
        );
    }
    return CILocalized(
        @"RETURN_HOME_MODE_YOUPIP",
        @"YouPiP (automatic Picture in Picture)"
    );
}

static BOOL CIParseCaptionAdvance(
    NSString *value,
    NSTimeInterval *result
) {
    NSString *normalized = [[value ?: @"" stringByReplacingOccurrencesOfString:@","
        withString:@"."] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (normalized.length == 0) {
        if (result) *result = 0;
        return YES;
    }
    NSScanner *scanner = [NSScanner scannerWithString:normalized];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double number = 0;
    BOOL valid = [scanner scanDouble:&number] &&
        scanner.isAtEnd && isfinite(number);
    if (valid && result) *result = number;
    return valid;
}

@interface CICaptionAdvanceValidator : NSObject
@property (nonatomic, weak) UIAlertAction *saveAction;
- (void)captionAdvanceDidChange:(UITextField *)field;
@end

@implementation CICaptionAdvanceValidator

- (void)captionAdvanceDidChange:(UITextField *)field {
    self.saveAction.enabled =
        CIParseCaptionAdvance(field.text, NULL);
}

@end

static const void *CICaptionAdvanceValidatorKey =
    &CICaptionAdvanceValidatorKey;

@interface CILRCLIBURLValidator : NSObject
@property (nonatomic, weak) UIAlertAction *saveAction;
- (void)URLDidChange:(UITextField *)field;
@end

@implementation CILRCLIBURLValidator

- (void)URLDidChange:(UITextField *)field {
    self.saveAction.enabled =
        CINormalizedLRCLIBBaseURL(field.text, NULL).length > 0;
}

@end

static const void *CILRCLIBURLValidatorKey =
    &CILRCLIBURLValidatorKey;

/// Owns the document picker for a lyric import.
///
/// UIKit only holds the picker's delegate weakly, and the settings screen has no
/// object of its own to hang this on, so the importer keeps itself alive via an
/// associated object on the presenting controller until the picker finishes.
@interface CILRCLIBCacheImporter : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) YTSettingsViewController *settingsViewController;
@end

static const void *CILRCLIBCacheImporterKey = &CILRCLIBCacheImporterKey;

@implementation CILRCLIBCacheImporter

- (void)finish {
    YTSettingsViewController *controller = self.settingsViewController;
    if (controller) {
        objc_setAssociatedObject(
            controller,
            CILRCLIBCacheImporterKey,
            nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
}

- (void)documentPicker:(__unused UIDocumentPickerViewController *)picker
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    NSURL *URL = URLs.firstObject;
    YTSettingsViewController *controller = self.settingsViewController;
    if (!URL) {
        [self finish];
        return;
    }
    // A picked file lives outside the sandbox, so the read has to happen inside
    // a coordinated security-scoped access.
    BOOL scoped = [URL startAccessingSecurityScopedResource];
    NSError *error = nil;
    NSUInteger imported =
        [CILRCLIBProvider importCacheFromURL:URL error:&error];
    if (scoped) [URL stopAccessingSecurityScopedResource];

    if (imported > 0) {
        [CICaptionCoordinator.sharedCoordinator reloadPreferences];
        [controller reloadData];
        CIShowToast([NSString stringWithFormat:CILocalized(
            @"LRCLIB_CACHE_IMPORT_DONE",
            @"Imported %lu songs."
        ), (unsigned long)imported]);
    } else {
        CIShowToast(error.localizedDescription ?: CILocalized(
            @"LRCLIB_CACHE_IMPORT_FAILED",
            @"Could not import that file."
        ));
    }
    [self finish];
}

- (void)documentPickerWasCancelled:
    (__unused UIDocumentPickerViewController *)picker {
    [self finish];
}

@end

static void CIPresentLRCLIBCacheImport(
    YTSettingsViewController *settingsViewController
) {
    CILRCLIBCacheImporter *importer = [CILRCLIBCacheImporter new];
    importer.settingsViewController = settingsViewController;
    objc_setAssociatedObject(
        settingsViewController,
        CILRCLIBCacheImporterKey,
        importer,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    // Exports are binary property lists. Accept generic data too, since a file
    // that has travelled through AirDrop or another app can lose its type.
    UTType *propertyList =
        [UTType typeWithIdentifier:@"com.apple.property-list"];
    NSArray<UTType *> *types = propertyList
        ? @[propertyList, UTTypeData] : @[UTTypeData];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:types];
    picker.delegate = importer;
    picker.allowsMultipleSelection = NO;
    [settingsViewController presentViewController:picker
                                        animated:YES
                                      completion:nil];
}

static void CIPresentLRCLIBCacheExport(
    YTSettingsViewController *settingsViewController
) {
    NSError *error = nil;
    NSURL *URL = [CILRCLIBProvider exportCacheWithError:&error];
    if (!URL) {
        CIShowToast(error.localizedDescription ?: CILocalized(
            @"LRCLIB_CACHE_EXPORT_FAILED",
            @"Could not export the saved lyrics."
        ));
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[URL]
        applicationActivities:nil];
    share.popoverPresentationController.sourceView =
        settingsViewController.view;
    share.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(settingsViewController.view.bounds),
                   CGRectGetMidY(settingsViewController.view.bounds),
                   1, 1);
    [settingsViewController presentViewController:share
                                        animated:YES
                                      completion:nil];
}

static void CIPresentLRCLIBCache(
    YTSettingsViewController *settingsViewController
) {
    CILRCLIBCacheSummary *summary = [CILRCLIBProvider cacheSummary];
    NSString *message = [NSString stringWithFormat:CILocalized(
        @"LRCLIB_CACHE_SUMMARY",
        @"%lu songs saved, %lu lookups remembered as having no lyrics, %@ on disk."
    ), (unsigned long)summary.lyricCount,
       (unsigned long)summary.missCount,
       [NSByteCountFormatter stringFromByteCount:(long long)summary.byteCount
                                      countStyle:NSByteCountFormatterCountStyleFile]];

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:CILocalized(@"LRCLIB_CACHE", @"Saved lyrics")
        message:message
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"LRCLIB_CACHE_BROWSE", @"Manage saved lyrics…")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [settingsViewController pushViewController:
                [CILRCLIBCacheViewController new]];
        }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"LRCLIB_CACHE_EXPORT", @"Export…")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            CIPresentLRCLIBCacheExport(settingsViewController);
        }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"LRCLIB_CACHE_IMPORT", @"Import…")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            CIPresentLRCLIBCacheImport(settingsViewController);
        }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"LRCLIB_CLEAR_CACHE", @"Clear")
        style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [CILRCLIBProvider clearPersistentCache];
            [CICaptionCoordinator.sharedCoordinator reloadPreferences];
            [settingsViewController reloadData];
            CIShowToast(CILocalized(
                @"LRCLIB_CLEAR_CACHE_DONE",
                @"LRCLIB lookup cache cleared."
            ));
        }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil]];

    // Required on iPad, where an action sheet must be anchored.
    sheet.popoverPresentationController.sourceView =
        settingsViewController.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(settingsViewController.view.bounds),
                   CGRectGetMidY(settingsViewController.view.bounds),
                   1, 1);
    [settingsViewController presentViewController:sheet
                                        animated:YES
                                      completion:nil];
}

static void CIPresentLRCLIBBaseURL(
    YTSettingsViewController *settingsViewController
) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CILocalized(
            @"LRCLIB_BASE_URL",
            @"LRCLIB base URL"
        )
        message:CILocalized(
            @"LRCLIB_BASE_URL_MESSAGE",
            @"Enter the root URL of the LRCLIB-compatible service. /api/search is appended automatically. To support arbitrary HTTP mirrors, this build permits cleartext connections app-wide; use HTTPS whenever possible."
        )
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = CILRCLIBBaseURL();
        field.placeholder = CILRCLIBDefaultBaseURL();
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType =
            UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode =
            UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:CILocalized(
            @"LRCLIB_BASE_URL_RESET",
            @"Use official server"
        )
        style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults
                removeObjectForKey:CILRCLIBBaseURLKey];
            [CICaptionCoordinator.sharedCoordinator
                reloadPreferences];
            [settingsViewController reloadData];
            CIShowToast(CILocalized(
                @"LRCLIB_BASE_URL_RESET_DONE",
                @"Restored the official LRCLIB server."
            ));
        }]];
    UIAlertAction *saveAction = [UIAlertAction
        actionWithTitle:CILocalized(@"SAVE", @"Save")
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *normalized =
                CINormalizedLRCLIBBaseURL(
                    alert.textFields.firstObject.text,
                    NULL
                );
            if (normalized.length == 0) {
                CIShowToast(CILocalized(
                    @"LRCLIB_BASE_URL_INVALID",
                    @"Enter a valid HTTP or HTTPS base URL."
                ));
                return;
            }
            [NSUserDefaults.standardUserDefaults
                setObject:normalized
                   forKey:CILRCLIBBaseURLKey];
            [CICaptionCoordinator.sharedCoordinator
                reloadPreferences];
            [settingsViewController reloadData];
            CIShowToast(CILocalized(
                @"LRCLIB_BASE_URL_SAVED",
                @"LRCLIB server saved and the current lookup was restarted."
            ));
        }];
    [alert addAction:saveAction];
    CILRCLIBURLValidator *validator =
        [CILRCLIBURLValidator new];
    validator.saveAction = saveAction;
    [alert.textFields.firstObject
        addTarget:validator
           action:@selector(URLDidChange:)
 forControlEvents:UIControlEventEditingChanged];
    objc_setAssociatedObject(
        alert,
        CILRCLIBURLValidatorKey,
        validator,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
    [validator URLDidChange:alert.textFields.firstObject];
    [settingsViewController presentViewController:alert
                                         animated:YES
                                       completion:nil];
}

static void CIPresentGlobalLanguagePriorities(
    YTSettingsViewController *settingsViewController
) {
    CILanguagePriorityViewController *controller =
        [[CILanguagePriorityViewController alloc]
            initWithTitle:CILocalized(
                @"LANGUAGE_PRIORITY",
                @"Caption language priority"
            )
            priorities:CICaptionLanguagePriorities()
            resetActionTitle:CILocalized(
                @"LANGUAGE_PRIORITY_RESET",
                @"Restore default order"
            )
            completion:^(NSArray<NSString *> *priorities) {
                CISetCaptionLanguagePriorities(priorities);
                [CICaptionCoordinator.sharedCoordinator
                    reloadPreferences];
                [settingsViewController reloadData];
                CIShowToast(CILocalized(
                    @"LANGUAGE_PRIORITY_SAVED",
                    @"Caption language order saved."
                ));
            }];
    [settingsViewController pushViewController:controller];
}

static void CIPresentCurrentVideoLanguagePriorities(
    YTSettingsViewController *settingsViewController
) {
    [CICaptionCoordinator.sharedCoordinator
        currentVideoContextWithCompletion:^(CIVideoContext *context) {
        if (!context.videoID.length) {
            CIShowToast(CILocalized(
                @"VIDEO_OVERRIDE_NO_VIDEO",
                @"Open a video first, then return here."
            ));
            return;
        }
        CIVideoOverride *override =
            CIVideoOverrideForVideoID(context.videoID);
        NSArray<NSString *> *priorities =
            override.captionLanguagePriorities.count > 0
                ? override.captionLanguagePriorities
                : CICaptionLanguagePriorities();
        CILanguagePriorityViewController *controller =
            [[CILanguagePriorityViewController alloc]
                initWithTitle:CILocalized(
                    @"VIDEO_LANGUAGE_PRIORITY",
                    @"Current video caption languages"
                )
                priorities:priorities
                resetActionTitle:CILocalized(
                    @"VIDEO_LANGUAGE_PRIORITY_INHERIT",
                    @"Use global order for this video"
                )
                completion:^(NSArray<NSString *> *savedPriorities) {
                    CISaveVideoCaptionLanguagePriorities(
                        context.videoID,
                        savedPriorities,
                        context.title
                    );
                    [CICaptionCoordinator.sharedCoordinator
                        reloadPreferences];
                    [settingsViewController reloadData];
                    CIShowToast(savedPriorities.count > 0
                        ? CILocalized(
                            @"VIDEO_LANGUAGE_PRIORITY_SAVED",
                            @"Saved the language order for this video."
                        )
                        : CILocalized(
                            @"VIDEO_LANGUAGE_PRIORITY_RESET_DONE",
                            @"This video now uses the global language order."
                        ));
                }];
        if (!settingsViewController.viewIfLoaded.window) return;
        [settingsViewController pushViewController:controller];
    }];
}

static void CIPresentCurrentVideoOverride(
    YTSettingsViewController *settingsViewController
) {
    [CICaptionCoordinator.sharedCoordinator
        currentVideoContextWithCompletion:^(CIVideoContext *context) {
        if (!context.videoID.length) {
            CIShowToast(CILocalized(
                @"VIDEO_OVERRIDE_NO_VIDEO",
                @"Open a video first, then return here."
            ));
            return;
        }

        NSString *automaticTitle = @"";
        NSString *automaticArtist = @"";
        CISplitSongMetadata(
            context.title,
            context.author,
            &automaticTitle,
            &automaticArtist
        );
        CIVideoOverride *override =
            CIVideoOverrideForVideoID(context.videoID);
        NSString *message = [NSString stringWithFormat:
            CILocalized(
                @"VIDEO_OVERRIDE_MESSAGE",
                @"Video: %@\nDetected title: %@\nDetected artist: %@\nPositive seconds display captions earlier."
            ),
            context.title.length > 0 ? context.title : context.videoID,
            automaticTitle.length > 0 ? automaticTitle : @"—",
            automaticArtist.length > 0 ? automaticArtist : @"—"
        ];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:CILocalized(
                @"VIDEO_OVERRIDE_TITLE",
                @"Current video lyric settings"
            )
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = automaticTitle.length > 0
                ? automaticTitle
                : CILocalized(@"VIDEO_OVERRIDE_SEARCH_TITLE", @"LRCLIB search title");
            field.text = override.searchTitle ?: @"";
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = automaticArtist.length > 0
                ? automaticArtist
                : CILocalized(@"VIDEO_OVERRIDE_SEARCH_ARTIST", @"Artist (optional)");
            field.text = override.searchArtist ?: @"";
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = CILocalized(
                @"VIDEO_OVERRIDE_ADVANCE",
                @"Caption advance seconds (+ earlier)"
            );
            if (override &&
                fabs(override.captionAdvanceSeconds) >= 0.001) {
                field.text = [NSString stringWithFormat:@"%.3g",
                    override.captionAdvanceSeconds];
            }
            field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        }];
        [alert addAction:[UIAlertAction
            actionWithTitle:CILocalized(@"CANCEL", @"Cancel")
            style:UIAlertActionStyleCancel
            handler:nil]];
        if (override) {
            [alert addAction:[UIAlertAction
                actionWithTitle:CILocalized(
                    @"VIDEO_OVERRIDE_RESET",
                    @"Reset for this video"
                )
                style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *action) {
                    CIClearVideoOverride(context.videoID);
                    [CICaptionCoordinator.sharedCoordinator
                        reloadPreferences];
                    [settingsViewController reloadData];
                    CIShowToast(CILocalized(
                        @"VIDEO_OVERRIDE_RESET_DONE",
                        @"Video-specific settings reset."
                    ));
                }]];
        }
        UIAlertAction *saveAction = [UIAlertAction
            actionWithTitle:CILocalized(@"SAVE", @"Save")
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                NSTimeInterval advance = 0;
                if (!CIParseCaptionAdvance(
                        alert.textFields[2].text,
                        &advance)) {
                    CIShowToast(CILocalized(
                        @"VIDEO_OVERRIDE_INVALID_ADVANCE",
                        @"Enter a valid number of seconds."
                    ));
                    return;
                }
                BOOL timingWasClamped = fabs(advance) > 30.0;
                advance = MAX(-30.0, MIN(30.0, advance));
                CISaveVideoOverride(
                    context.videoID,
                    alert.textFields[0].text,
                    alert.textFields[1].text,
                    advance,
                    context.title
                );
                [CICaptionCoordinator.sharedCoordinator
                    reloadPreferences];
                [settingsViewController reloadData];
                CIShowToast(timingWasClamped
                    ? CILocalized(
                        @"VIDEO_OVERRIDE_CLAMPED",
                        @"Saved; caption timing was limited to 30 seconds."
                    )
                    : CILocalized(
                        @"VIDEO_OVERRIDE_SAVED",
                        @"Video-specific lyric settings saved."
                    ));
            }];
        [alert addAction:saveAction];
        CICaptionAdvanceValidator *validator =
            [CICaptionAdvanceValidator new];
        validator.saveAction = saveAction;
        [alert.textFields[2] addTarget:validator
            action:@selector(captionAdvanceDidChange:)
            forControlEvents:UIControlEventEditingChanged];
        objc_setAssociatedObject(
            alert,
            CICaptionAdvanceValidatorKey,
            validator,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
        [validator captionAdvanceDidChange:alert.textFields[2]];
        if (!settingsViewController.viewIfLoaded.window) return;
        [settingsViewController presentViewController:alert
                                             animated:YES
                                           completion:nil];
    }];
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

    NSString *languageTitle = CILocalized(
        @"LANGUAGE_PRIORITY",
        @"Caption language priority"
    );
    YTSettingsSectionItem *language = [%c(YTSettingsSectionItem)
        itemWithTitle:languageTitle
        titleDescription:CILocalized(
            @"LANGUAGE_PRIORITY_DESCRIPTION",
            @"Drag YouTube caption languages into priority order. Original manual CC and ASR tracks are supported; auto-translation is excluded."
        )
        accessibilityIdentifier:@"CaptionIsland.Language"
        detailTextBlock:^NSString *{
            return CICaptionLanguagePrioritySummary(
                CICaptionLanguagePriorities()
            );
        }
        selectBlock:^BOOL(__unused YTSettingsCell *cell, __unused NSUInteger sectionItemIndex) {
            CIPresentGlobalLanguagePriorities(
                settingsViewController
            );
            return YES;
        }];
    [items addObject:language];

    NSString *returnHomeModeTitle = CILocalized(
        @"RETURN_HOME_MODE",
        @"Return to Home Screen mode"
    );
    NSArray<NSNumber *> *returnHomeModeChoices = @[
        @(CIReturnHomeModeYouPiP),
        @(CIReturnHomeModeCaptionIsland),
    ];
    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:returnHomeModeTitle
        titleDescription:CILocalized(
            @"RETURN_HOME_MODE_DESCRIPTION",
            @"Choose automatic Picture in Picture or background captions when leaving YouTube. The manual PiP button remains available."
        )
        accessibilityIdentifier:@"CaptionIsland.ReturnHomeMode"
        detailTextBlock:^NSString * {
            return CIReturnHomeModeTitle(CICurrentReturnHomeMode());
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            NSMutableArray<YTSettingsSectionItem *> *rows =
                [NSMutableArray arrayWithCapacity:
                    returnHomeModeChoices.count];
            for (NSNumber *choice in returnHomeModeChoices) {
                CIReturnHomeMode mode =
                    (CIReturnHomeMode)choice.integerValue;
                [rows addObject:[%c(YTSettingsSectionItem)
                    checkmarkItemWithTitle:CIReturnHomeModeTitle(mode)
                    selectBlock:^BOOL(
                        __unused YTSettingsCell *pickerCell,
                        __unused NSUInteger pickerIndex
                    ) {
                        CIStoreInteger(
                            CIReturnHomeModeKey,
                            choice.integerValue
                        );
                        [settingsViewController reloadData];
                        return YES;
                    }]];
            }
            NSUInteger selected = [returnHomeModeChoices
                indexOfObject:@(CICurrentReturnHomeMode())];
            if (selected == NSNotFound) selected = 0;
            YTSettingsPickerViewController *picker =
                [[%c(YTSettingsPickerViewController) alloc]
                    initWithNavTitle:returnHomeModeTitle
                    pickerSectionTitle:nil
                    rows:rows
                    selectedItemIndex:selected
                    parentResponder:
                        [settingsViewController parentResponder]];
            [settingsViewController pushViewController:picker];
            return YES;
        }]];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(
            @"LAUNCH_PREFETCH_RETENTION_PROBE",
            @"Retain LaunchPrefetch assertion"
        )
        titleDescription:CILocalized(
            @"LAUNCH_PREFETCH_RETENTION_PROBE_DESCRIPTION",
            @"High-risk experiment: intercept Apple's client-side invalidation of this process's LaunchPrefetch assertion. Enable it, then fully terminate and reopen YouTube. Disable it to release retained assertions."
        )
        accessibilityIdentifier:
            @"CaptionIsland.LaunchPrefetchRetentionProbe"
        switchOn:CIPreferenceBool(
            CILaunchPrefetchRetentionProbeEnabledKey,
            NO
        )
        switchBlock:^BOOL(
            __unused YTSettingsCell *cell,
            BOOL enabled
        ) {
            CIStoreBool(
                CILaunchPrefetchRetentionProbeEnabledKey,
                enabled
            );
            CIReloadLaunchPrefetchRetentionProbe();
            return YES;
        } settingItemId:0]];

    NSString *sourcePriorityTitle =
        CILocalized(@"SOURCE_PRIORITY", @"Preferred caption source");
    NSArray<NSNumber *> *sourcePriorityChoices = @[
        @(CISourcePriorityLRCLIBFirst),
        @(CISourcePriorityYouTubeFirst),
    ];
    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:sourcePriorityTitle
        titleDescription:CILocalized(
            @"SOURCE_PRIORITY_DESCRIPTION",
            @"Choose whether LRCLIB or YouTube captions are tried first."
        )
        accessibilityIdentifier:@"CaptionIsland.SourcePriority"
        detailTextBlock:^NSString * {
            return CISourcePriorityTitle(CISourcePriority());
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            NSMutableArray<YTSettingsSectionItem *> *rows =
                [NSMutableArray arrayWithCapacity:
                    sourcePriorityChoices.count];
            for (NSNumber *choice in sourcePriorityChoices) {
                CISourcePriorityMode mode =
                    (CISourcePriorityMode)choice.integerValue;
                [rows addObject:[%c(YTSettingsSectionItem)
                    checkmarkItemWithTitle:CISourcePriorityTitle(mode)
                    selectBlock:^BOOL(
                        __unused YTSettingsCell *pickerCell,
                        __unused NSUInteger pickerIndex
                    ) {
                        CIStoreInteger(
                            CISourcePriorityKey,
                            choice.integerValue
                        );
                        [settingsViewController reloadData];
                        return YES;
                    }]];
            }
            NSUInteger selected = [sourcePriorityChoices
                indexOfObject:@(CISourcePriority())];
            if (selected == NSNotFound) selected = 0;
            YTSettingsPickerViewController *picker =
                [[%c(YTSettingsPickerViewController) alloc]
                    initWithNavTitle:sourcePriorityTitle
                    pickerSectionTitle:nil
                    rows:rows
                    selectedItemIndex:selected
                    parentResponder:
                        [settingsViewController parentResponder]];
            [settingsViewController pushViewController:picker];
            return YES;
        }]];

    [items addObject:[%c(YTSettingsSectionItem)
        switchItemWithTitle:CILocalized(@"DISABLE_FOR_SHORTS", @"Disable for Shorts")
        titleDescription:CILocalized(@"DISABLE_FOR_SHORTS_DESCRIPTION", @"Do not start a Live Activity or search for lyrics while watching Shorts.")
        accessibilityIdentifier:@"CaptionIsland.DisableForShorts"
        switchOn:CIPreferenceBool(CIDisableForShortsKey, YES)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            CIStoreBool(CIDisableForShortsKey, enabled);
            CISynchronizeContinuedTaskFromCurrentVideo();
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
                        CISynchronizeContinuedTaskFromCurrentVideo();
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
        switchItemWithTitle:CILocalized(@"EXTERNAL_LYRICS", @"LRCLIB lyrics")
        titleDescription:CILocalized(@"EXTERNAL_LYRICS_DESCRIPTION", @"Allow synchronized or plain lyrics from LRCLIB in the selected source order.")
        accessibilityIdentifier:@"CaptionIsland.ExternalLyrics"
        switchOn:CIPreferenceBool(CIExternalLyricsEnabledKey, YES)
        switchBlock:^BOOL(__unused YTSettingsCell *cell, BOOL enabled) {
            CIStoreBool(CIExternalLyricsEnabledKey, enabled);
            return YES;
        } settingItemId:0]];

    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:CILocalized(
            @"LRCLIB_BASE_URL",
            @"LRCLIB base URL"
        )
        titleDescription:CILocalized(
            @"LRCLIB_BASE_URL_DESCRIPTION",
            @"Use the official service, a compatible mirror, or your own LRCLIB instance. HTTP and HTTPS are accepted."
        )
        accessibilityIdentifier:@"CaptionIsland.LRCLIBBaseURL"
        detailTextBlock:^NSString * {
            return CILRCLIBBaseURL();
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            CIPresentLRCLIBBaseURL(settingsViewController);
            return YES;
        }]];

    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:CILocalized(
            @"LRCLIB_CACHE",
            @"Saved lyrics"
        )
        titleDescription:CILocalized(
            @"LRCLIB_CACHE_DESCRIPTION",
            @"Export the saved lyrics to move them to another device, import a previous export, or forget everything and look the current video up again."
        )
        accessibilityIdentifier:@"CaptionIsland.LRCLIBCache"
        detailTextBlock:^NSString * {
            CILRCLIBCacheSummary *summary =
                [CILRCLIBProvider cacheSummary];
            return [NSString stringWithFormat:CILocalized(
                @"LRCLIB_CACHE_COUNT",
                @"%lu songs"
            ), (unsigned long)summary.lyricCount];
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            CIPresentLRCLIBCache(settingsViewController);
            return YES;
        }]];

    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:CILocalized(
            @"VIDEO_OVERRIDE",
            @"Current video lyric settings"
        )
        titleDescription:CILocalized(
            @"VIDEO_OVERRIDE_DESCRIPTION",
            @"Override the LRCLIB title, artist, and caption timing for the current video."
        )
        accessibilityIdentifier:@"CaptionIsland.VideoOverride"
        detailTextBlock:^NSString * {
            return [NSString stringWithFormat:CILocalized(
                @"VIDEO_OVERRIDE_COUNT",
                @"%lu videos saved"
            ), (unsigned long)CIVideoOverrideCount()];
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            CIPresentCurrentVideoOverride(settingsViewController);
            return YES;
        }]];

    [items addObject:[%c(YTSettingsSectionItem)
        itemWithTitle:CILocalized(
            @"VIDEO_LANGUAGE_PRIORITY",
            @"Current video caption languages"
        )
        titleDescription:CILocalized(
            @"VIDEO_LANGUAGE_PRIORITY_DESCRIPTION",
            @"Save a separate YouTube caption-language order for the video that is currently playing."
        )
        accessibilityIdentifier:
            @"CaptionIsland.VideoLanguagePriority"
        detailTextBlock:^NSString * {
            return CILocalized(
                @"VIDEO_LANGUAGE_PRIORITY_OPEN",
                @"Configure"
            );
        }
        selectBlock:^BOOL(
            __unused YTSettingsCell *cell,
            __unused NSUInteger sectionItemIndex
        ) {
            CIPresentCurrentVideoLanguagePriorities(
                settingsViewController
            );
            return YES;
        }]];

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
            titleDescription:CISourcePriorityDescription() headerHidden:NO];
    } else if ([settingsViewController respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
        [settingsViewController setSectionItems:items forCategory:CaptionIslandSection
            title:CILocalized(@"SETTINGS_TITLE", @"Caption Island")
            titleDescription:CISourcePriorityDescription() headerHidden:NO];
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
