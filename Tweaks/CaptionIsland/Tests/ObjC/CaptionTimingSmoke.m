#import <Foundation/Foundation.h>
#import <math.h>
#import "../../CICaptionTiming.h"

static void CIAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"Caption timing smoke failed: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        CIAssert(
            fabs(CIAdjustedCaptionLookupTime(5.0, 2.0) - 7.0) < 0.001,
            @"a positive advance should look ahead"
        );
        CIAssert(
            fabs(CIAdjustedCaptionBoundary(6.0, 2.0) - 4.0) < 0.001,
            @"a positive advance should move an ActivityKit boundary earlier"
        );
        CIAssert(
            fabs(CIAdjustedCaptionLookupTime(0.0, -2.0) + 2.0) < 0.001,
            @"a negative advance must preserve pre-roll before a zero-time cue"
        );
        CIAssert(
            fabs(CIAdjustedCaptionBoundary(0.0, -2.0) - 2.0) < 0.001,
            @"a negative advance should delay a zero-time ActivityKit boundary"
        );
        NSLog(@"Caption timing smoke passed");
    }
    return 0;
}
