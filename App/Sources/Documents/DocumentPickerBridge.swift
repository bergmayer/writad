import UIKit
import UniformTypeIdentifiers

/// UIKit-direct presenter for `UIDocumentPickerViewController`.
/// Kept as an escape hatch for code paths that can't rely on the
/// SwiftUI `.fileImporter` chain.
@MainActor
final class DocumentPickerBridge: NSObject {

    static let shared = DocumentPickerBridge()

    private var openDelegate: OpenDelegate?

    /// Present the system Open picker. On success, routes the URL via
    /// `AppStateBus.routeOpenURL` so the file lands in a fresh window
    /// or tab per the user's `DocumentDestination` preference.
    func presentOpenPicker() {
        guard let presenter = topPresentingController() else { return }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: PlainTextDocument.supportedReadTypes,
            asCopy: false
        )
        let delegate = OpenDelegate { [weak self] url in
            self?.openDelegate = nil
            if let route = AppStateBus.shared.scenes.routeOpenURL {
                route(url)
            } else {
                // Cold-launch fallback: no editor scene has installed
                // the router yet. Spawn one with the URL queued.
                AppStateBus.shared.pending.newWindow = url
                AppStateBus.shared.scenes.openWindowAction?(.editor)
            }
        } onCancel: { [weak self] in
            self?.openDelegate = nil
        }
        openDelegate = delegate
        picker.delegate = delegate
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    /// Find the top-most view controller that can present a sheet —
    /// walks each connected `UIWindowScene`, picks the key window's
    /// root, then descends through presented controllers.
    private func topPresentingController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            // Active scenes first; among those, prefer the key window.
            .sorted { lhs, rhs in
                let lhsActive = lhs.activationState == .foregroundActive
                let rhsActive = rhs.activationState == .foregroundActive
                if lhsActive != rhsActive { return lhsActive }
                return false
            }
        for scene in scenes {
            let candidate = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
            guard let root = candidate?.rootViewController else { continue }
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
        return nil
    }
}

/// Lightweight delegate retained for the duration of the picker session.
@MainActor
private final class OpenDelegate: NSObject, UIDocumentPickerDelegate {

    private let onPick: (URL) -> Void
    private let onCancel: () -> Void

    init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { onCancel(); return }
        onPick(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel()
    }
}
