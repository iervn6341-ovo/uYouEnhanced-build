#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *CICleanCaptionText(NSString * _Nullable text);
FOUNDATION_EXPORT NSString *CINormalizedText(NSString * _Nullable text);
FOUNDATION_EXPORT NSArray<NSString *> *CINonEmptyLines(NSString * _Nullable text);
FOUNDATION_EXPORT double CITextSimilarity(NSString *lhs, NSString *rhs);
FOUNDATION_EXPORT NSString *CISongTitleFromVideoTitle(NSString * _Nullable videoTitle);
FOUNDATION_EXPORT void CISplitSongMetadata(NSString * _Nullable videoTitle,
                                          NSString * _Nullable videoAuthor,
                                          NSString * _Nullable __autoreleasing * _Nullable songTitle,
                                          NSString * _Nullable __autoreleasing * _Nullable artist);

NS_ASSUME_NONNULL_END
