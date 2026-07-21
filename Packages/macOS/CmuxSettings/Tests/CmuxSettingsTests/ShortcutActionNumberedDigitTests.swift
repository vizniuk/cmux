import Foundation
import Testing
@testable import CmuxSettings

@Suite("ShortcutAction numbered digit matching")
struct ShortcutActionNumberedDigitTests {
    @Test func onlyNumberedSelectionActionsUseDigitMatching() {
        for action in ShortcutAction.allCases {
            let expected = action == .selectSurfaceByNumber || action == .selectWorkspaceByNumber
            #expect(
                action.usesNumberedDigitMatching == expected,
                "\(action) usesNumberedDigitMatching should be \(expected)"
            )
        }
    }

    @Test func diffViewerScrollToTopDefaultIsChord() {
        #expect(
            ShortcutAction.diffViewerScrollToTop.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "g"),
                second: ShortcutStroke(key: "g")
            )
        )
    }

    @Test func diffViewerFileNavigationDefaultsAreMnemonicChords() {
        #expect(
            ShortcutAction.diffViewerNextFile.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "]"),
                second: ShortcutStroke(key: "f")
            )
        )
        #expect(
            ShortcutAction.diffViewerPreviousFile.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "["),
                second: ShortcutStroke(key: "f")
            )
        )
    }

    @Test func fileExplorerOpenSelectionDefaultsMatchKeyboardOpenPolicy() {
        #expect(
            ShortcutAction.fileExplorerOpenSelection.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "\r")
            )
        )
        #expect(
            ShortcutAction.fileExplorerOpenSelectionFinderAlias.defaultShortcut == StoredShortcut(
                first: ShortcutStroke(key: "↓", command: true)
            )
        )
    }

    @Test func onlyFocusedContentActionsAllowBareFirstStrokes() {
        let bareFirstStrokeActions: Set<ShortcutAction> = [
            .diffViewerScrollDown,
            .diffViewerScrollUp,
            .diffViewerScrollHalfPageDown,
            .diffViewerScrollHalfPageUp,
            .diffViewerScrollDownEmacs,
            .diffViewerScrollUpEmacs,
            .diffViewerScrollToBottom,
            .diffViewerScrollToTop,
            .diffViewerOpenFileSearch,
            .diffViewerNextFile,
            .diffViewerPreviousFile,
            .fileExplorerOpenSelection,
            .fileExplorerOpenSelectionFinderAlias,
        ]

        for action in ShortcutAction.allCases {
            #expect(
                action.allowsBareFirstStroke == bareFirstStrokeActions.contains(action),
                "\(action) allowsBareFirstStroke should match focused content shortcut policy"
            )
        }
    }

    @Test func fileExplorerOpenSelectionShortcutsAreSingleStrokeOnly() {
        #expect(!ShortcutAction.fileExplorerOpenSelection.allowsChordShortcut)
        #expect(!ShortcutAction.fileExplorerOpenSelectionFinderAlias.allowsChordShortcut)
    }

    @Test func copyAgentReportUsesEstablishedConfigurableShortcutContract() {
        let action = ShortcutAction.copyAgentReport

        #expect(action.defaultShortcut == StoredShortcut(
            first: ShortcutStroke(key: "c", command: true, shift: true)
        ))
        #expect(action.group == .workspace)
        #expect(ShortcutAction.settingsVisibleActions.contains(action))
        #expect(
            action.defaultFocusWhenClause
                == .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        )
        #expect(action.isReservedShortcut(StoredShortcut(
            first: ShortcutStroke(key: "c", command: true)
        )))
        #expect(action.isReservedShortcut(StoredShortcut(
            first: ShortcutStroke(key: "c", command: true),
            second: ShortcutStroke(key: "r")
        )))
        #expect(!action.isReservedShortcut(action.defaultShortcut!))
    }

    @Test func clearAllNotificationsUsesUnboundWorkspaceShortcutContract() throws {
        let action = ShortcutAction.clearAllNotifications
        let visibleActions = ShortcutAction.settingsVisibleActions
        let actionIndex = try #require(visibleActions.firstIndex(of: action))
        let notificationAnchorIndex = try #require(
            visibleActions.firstIndex(of: .markOldestUnreadAndJumpNext)
        )
        let rightSidebarIndex = try #require(visibleActions.firstIndex(of: .focusRightSidebar))
        let commandC = StoredShortcut(first: ShortcutStroke(key: "c", command: true))

        #expect(action.rawValue == "clearAllNotifications")
        #expect(ShortcutAction.allCases.filter { $0.rawValue == action.rawValue }.count == 1)
        #expect(action.defaultShortcut == nil)
        #expect(action.defaultStroke == nil)
        #expect(action.group == .workspace)
        #expect(action.defaultFocusWhenClause == .always)
        #expect(!action.allowsBareFirstStroke)
        #expect(action.allowsChordShortcut)
        #expect(actionIndex == notificationAnchorIndex + 1)
        #expect(actionIndex < rightSidebarIndex)
        #expect(
            action.displayName
                == String(
                    localized: "shortcut.clearAllNotifications.label",
                    defaultValue: "Clear All Notifications"
                )
        )
        #expect(!action.isReservedShortcut(commandC))
        #expect(ShortcutAction.copyAgentReport.isReservedShortcut(commandC))
        #expect(
            ShortcutAction.showNotifications.defaultShortcut
                == StoredShortcut(first: ShortcutStroke(key: "i", command: true))
        )
        #expect(
            ShortcutAction.jumpToUnread.defaultShortcut
                == StoredShortcut(first: ShortcutStroke(key: "u", command: true, shift: true))
        )
    }
}
