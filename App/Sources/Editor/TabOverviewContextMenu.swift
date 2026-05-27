import SwiftUI

/// Menu attached to the "show all tabs" button — both the iPad
/// chrome's `showAllTabsButton` in `TabBarView` and the iPhone
/// status bar's `phoneTabsButton`. The button now uses `Menu`
/// (tap = menu), so a single tap reaches every entry instead of
/// requiring a fragile long-press. "Show Tab Overview" leads so
/// the previous tap-to-open-switcher behavior is still one tap.
/// Keeping the entries here means the two surfaces stay in
/// lockstep instead of drifting as new tab-management commands
/// land.
struct TabOverviewContextMenu: View {

    var body: some View {
        Button {
            claimFocus()
            CommandActions.showTabSwitcher()
        } label: {
            Label("Show Tab Overview", systemImage: "square.on.square")
        }
        Divider()
        Button {
            claimFocus()
            CommandActions.newTab()
        } label: {
            Label("Open New Tab", systemImage: "plus.square")
        }
        Divider()
        Button(role: .destructive) {
            claimFocus()
            guard let session = AppStateBus.shared.scenes.currentSession else { return }
            CommandActions.requestCloseTab(session.selectedTabID, in: session)
        } label: {
            Label("Close This Tab", systemImage: "xmark")
        }
        Button(role: .destructive) {
            claimFocus()
            guard let session = AppStateBus.shared.scenes.currentSession else { return }
            CommandActions.requestCloseOtherTabs(except: session.selectedTabID, in: session)
        } label: {
            Label("Close Other Tabs", systemImage: "rectangle.stack.badge.minus")
        }
        Button(role: .destructive) {
            claimFocus()
            guard let session = AppStateBus.shared.scenes.currentSession else { return }
            CommandActions.requestCloseTabsToRight(of: session.selectedTabID, in: session)
        } label: {
            Label("Close Tabs to the Right", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
        }
        Button(role: .destructive) {
            claimFocus()
            guard let session = AppStateBus.shared.scenes.currentSession else { return }
            CommandActions.requestCloseAllTabs(in: session)
        } label: {
            Label("Close All Tabs", systemImage: "xmark.square.fill")
        }
    }

    /// Pin the active session as the current scene before firing
    /// the action — otherwise a tap-and-hold in window A while the
    /// bus's `currentSession` still points at window B would land
    /// the dialog / close in the wrong window.
    private func claimFocus() {
        guard let session = AppStateBus.shared.scenes.currentSession else { return }
        AppStateBus.shared.scenes.claimFocus(session: session)
    }
}
