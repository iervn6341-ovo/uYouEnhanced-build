#import <Foundation/Foundation.h>
#import <math.h>
#import "../../CIVideoEligibility.h"

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"Video eligibility smoke failed: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        CIAssert(
            CIVideoExclusionReasonForPlayback(YES, YES, 30, 5) ==
                CIVideoExclusionReasonShorts,
            @"Shorts should be excluded independently of duration"
        );
        CIAssert(
            CIVideoExclusionReasonForPlayback(YES, NO, 30, 5) ==
                CIVideoExclusionReasonNone,
            @"the Shorts preference should be reversible"
        );
        CIAssert(
            CIVideoExclusionReasonForPlayback(NO, YES, 299, 5) ==
                CIVideoExclusionReasonNone,
            @"videos below the limit should remain eligible"
        );
        CIAssert(
            CIVideoExclusionReasonForPlayback(NO, YES, 300, 5) ==
                CIVideoExclusionReasonNone,
            @"a video exactly at the limit should remain eligible"
        );
        CIAssert(
            CIVideoExclusionReasonForPlayback(NO, YES, 301, 5) ==
                CIVideoExclusionReasonDuration,
            @"videos over the limit should be excluded"
        );
        CIAssert(
            CIVideoExclusionReasonForPlayback(NO, YES, 3600, 0) ==
                CIVideoExclusionReasonNone,
            @"zero minutes should mean no duration limit"
        );
        CIAssert(
            CIVideoExclusionReasonForPlayback(NO, YES, NAN, 5) ==
                CIVideoExclusionReasonNone &&
            CIVideoExclusionReasonForPlayback(NO, YES, 0, 5) ==
                CIVideoExclusionReasonNone,
            @"unknown duration should not cause a false exclusion"
        );
        NSLog(@"Video eligibility smoke passed");
    }
    return 0;
}
