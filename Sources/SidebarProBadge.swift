import SwiftUI

/// Corner "Pro" badge in the sidebar footer: renders the active
/// ``ProBadgeStyle`` (Debug > Pro Badge Style switches variants) and opens
/// the shared pricing destination, same as the Settings Account card,
/// command palette entry, and Help menu item. Rendered in both the Release
/// footer and the DEBUG dev footer via `SidebarFooterButtons`.
struct SidebarProBadge: View {
    let isXmuxEdition: Bool

    init(isXmuxEdition: Bool = CmuxFeatureFlags.currentBuildIsXmuxEdition) {
        self.isXmuxEdition = isXmuxEdition
    }

    static func isVisible(isXmuxEdition: Bool) -> Bool {
        !isXmuxEdition
    }

    @ViewBuilder
    var body: some View {
        if Self.isVisible(isXmuxEdition: isXmuxEdition) {
            ProBadgeView()
        }
    }
}
