#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Presents the in-player Caption Island panel above whatever is on screen.
///
/// `sourceViewController` is only a hint: the player overlay hands us a view
/// whose own controller is often unsuitable for a modal — it can be mid-rotation
/// or already presenting — so the panel resolves the topmost presented
/// controller itself and falls back to the key window's root.
FOUNDATION_EXPORT void CIPresentPlayerControlPanel(
    UIViewController * _Nullable sourceViewController
);

NS_ASSUME_NONNULL_END
