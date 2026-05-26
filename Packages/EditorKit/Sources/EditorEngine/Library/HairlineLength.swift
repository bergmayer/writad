import UIKit

/// A single physical pixel in points. We have no view in scope here to
/// query its display scale, so we ask the trait collection for the
/// current process — which the system populates with the main screen's
/// scale on iOS/iPadOS. visionOS uses a fixed 1pt hairline because its
/// rendering doesn't backing-store at a single pixel.
#if os(visionOS)
let hairlineLength: CGFloat = 1
#else
let hairlineLength: CGFloat = {
    let scale = UITraitCollection.current.displayScale
    return scale > 0 ? 1 / scale : 1
}()
#endif
