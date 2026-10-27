import XCTest
@testable import StripKit

final class WindowSearchTests: XCTestCase {
    // MARK: fuzzyMatch

    func testSubsequenceMatchesAndReportsIndices() {
        let m = fuzzyMatch("fx", in: "Firefox")
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.indices.first, 0)
        XCTAssertNil(fuzzyMatch("xf", in: "Firefox"))
    }

    func testCaseAndDiacriticInsensitive() {
        XCTAssertNotNil(fuzzyMatch("CAFE", in: "Café menu"))
        XCTAssertNotNil(fuzzyMatch("résumé", in: "RESUME draft"))
    }

    func testEmptyPatternOrShortTextNeverMatches() {
        XCTAssertNil(fuzzyMatch("", in: "anything"))
        XCTAssertNil(fuzzyMatch("long", in: "lo"))
    }

    func testConsecutiveBeatsScattered() {
        let tight = fuzzyMatch("book", in: "bookings repo")!.score
        let loose = fuzzyMatch("book", in: "big old oak kit")!.score
        XCTAssertGreaterThan(tight, loose)
    }

    func testWordStartBeatsMidWord() {
        let start = fuzzyMatch("pr", in: "open PR review")!.score
        let mid = fuzzyMatch("pr", in: "ampere")!.score
        XCTAssertGreaterThan(start, mid)
    }

    func testPicksBestStartNotFirstOccurrence() {
        // The first "h" (in "the") would give a scattered match; the best start is "Hades".
        let m = fuzzyMatch("had", in: "the Hades soundtrack")!
        XCTAssertEqual(m.indices, [4, 5, 6])
    }

    func testShorterTextWinsOtherwiseEqual() {
        XCTAssertGreaterThan(fuzzyMatch("mail", in: "Mail")!.score,
                             fuzzyMatch("mail", in: "Mail — Inbox (1,204 messages) — work account folder")!.score)
    }

    // MARK: rankSearch

    private let candidates: [SearchCandidate] = [
        SearchCandidate(target: .window(1), title: "docs: add booking concept", appName: "Firefox", order: 0),
        SearchCandidate(target: .tab(window: 1, index: 0), title: "oolio-group/bookings", appName: "Firefox",
                        context: "docs: add booking concept", order: 1),
        SearchCandidate(target: .tab(window: 1, index: 2), title: "Hades - Out of Tartarus | YouTube Music",
                        appName: "Firefox", context: "docs: add booking concept", order: 2),
        SearchCandidate(target: .window(2), title: "Unread Messages - Slack", appName: "Slack", order: 3),
        SearchCandidate(target: .window(3), title: "[1/2] bookings.book-concept-doc", appName: "WezTerm", order: 4),
    ]

    func testEmptyQueryYieldsNothing() {
        XCTAssertTrue(rankSearch("", candidates).isEmpty)
        XCTAssertTrue(rankSearch("   ", candidates).isEmpty)
    }

    func testTabsAreSearchable() {
        let r = rankSearch("hades", candidates)
        XCTAssertEqual(r.first?.candidate.target, .tab(window: 1, index: 2))
    }

    func testEveryTokenMustMatchSomewhere() {
        // "slack" matches app, "unread" matches title → the Slack window.
        XCTAssertEqual(rankSearch("slack unread", candidates).map(\.candidate.target), [.window(2)])
        // "slack" + "hades" never co-occur.
        XCTAssertTrue(rankSearch("slack hades", candidates).isEmpty)
    }

    func testTokensCanSpanAppAndTitle() {
        // "fire" via app name, "hades" via title.
        XCTAssertEqual(rankSearch("fire hades", candidates).first?.candidate.target, .tab(window: 1, index: 2))
    }

    func testAppNameMatchListsAllThatAppsHits() {
        let targets = Set(rankSearch("wezterm", candidates).map(\.candidate.target))
        XCTAssertEqual(targets, [.window(3)])
    }

    func testTitleHighlightsComeFromTitleMatch() {
        // "slack" scores higher in the title than via the (down-weighted) app name, so the title
        // carries the highlight: "Unread Messages - Slack" → offsets 18…22.
        let r = rankSearch("slack", candidates).first!
        XCTAssertEqual(r.titleMatches, [18, 19, 20, 21, 22])
        XCTAssertTrue(r.appMatches.isEmpty)
    }

    func testTiesKeepCandidateOrder() {
        let same = [
            SearchCandidate(target: .window(10), title: "Notes", appName: "A", order: 0),
            SearchCandidate(target: .window(11), title: "Notes", appName: "A", order: 1),
        ]
        XCTAssertEqual(rankSearch("notes", same).map(\.candidate.target), [.window(10), .window(11)])
    }

    func testWindowBeatsTabWithSameTitle() {
        let c = [
            SearchCandidate(target: .tab(window: 1, index: 0), title: "Inbox", appName: "X", order: 0),
            SearchCandidate(target: .window(2), title: "Inbox", appName: "X", order: 1),
        ]
        XCTAssertEqual(rankSearch("inbox", c).first?.candidate.target, .window(2))
    }

    func testLimitCapsResults() {
        let many = (0 ..< 80).map {
            SearchCandidate(target: .window(CGWindowID($0)), title: "Doc \($0)", appName: "A", order: $0)
        }
        XCTAssertEqual(rankSearch("doc", many, limit: 10).count, 10)
    }

    // MARK: query editing

    func testQueryEdits() {
        XCTAssertEqual(applying(.insert("a"), to: "ab"), "aba")
        XCTAssertEqual(applying(.deleteBackward, to: "ab"), "a")
        XCTAssertEqual(applying(.deleteBackward, to: ""), "")
        XCTAssertEqual(applying(.deleteWord, to: "fire hades  "), "fire ")
        XCTAssertEqual(applying(.deleteWord, to: "single"), "")
        XCTAssertEqual(applying(.clear, to: "anything"), "")
    }

    // MARK: key mapping

    private func key(_ code: Int, _ chars: String = "", shift: Bool = false, control: Bool = false,
                     option: Bool = false, command: Bool = false) -> SearchKey? {
        searchKey(keyCode: code, shift: shift, control: control, option: option, command: command, chars: chars)
    }

    func testTypingInsertsLayoutCharacters() {
        XCTAssertEqual(key(0x04, "h"), .edit(.insert("h")))      // h types, it doesn't navigate
        XCTAssertEqual(key(0x31, " "), .edit(.insert(" ")))      // Space types, it doesn't close
        XCTAssertEqual(key(0x04, "H", shift: true), .edit(.insert("H")))
    }

    func testNavigationAndControlKeys() {
        XCTAssertEqual(key(0x24), .confirm)
        XCTAssertEqual(key(0x4C), .confirm)                      // keypad Enter
        XCTAssertEqual(key(0x35), .escape)
        XCTAssertEqual(key(0x7E), .up)
        XCTAssertEqual(key(0x7D), .down)
        XCTAssertEqual(key(0x30), .down)                         // Tab
        XCTAssertEqual(key(0x30, shift: true), .up)              // ⇧Tab
        XCTAssertEqual(key(0x23, control: true), .up)            // ⌃P
        XCTAssertEqual(key(0x2D, control: true), .down)          // ⌃N
    }

    func testDeletion() {
        XCTAssertEqual(key(0x33), .edit(.deleteBackward))
        XCTAssertEqual(key(0x33, option: true), .edit(.deleteWord))
        XCTAssertEqual(key(0x0D, control: true), .edit(.deleteWord))  // ⌃W
        XCTAssertEqual(key(0x33, command: true), .edit(.clear))
        XCTAssertEqual(key(0x20, control: true), .edit(.clear))       // ⌃U
    }

    func testCommandShortcutsAreSwallowedExceptSystemSwitchers() {
        XCTAssertEqual(key(0x09, "v", command: true), .paste)
        XCTAssertEqual(key(0x0D, "w", command: true), .ignore)   // ⌘W must not close the app behind
        XCTAssertEqual(key(0x0C, "q", command: true), .ignore)   // ⌘Q must not quit it
        XCTAssertNil(key(0x30, command: true))                   // ⌘Tab passes through
        XCTAssertNil(key(0x31, " ", command: true))              // ⌘Space (Spotlight) passes through
    }

    func testSystemSwitchersPassThroughAndCloseTheOverview() {
        XCTAssertTrue(systemPassThrough(keyCode: 0x30, command: true))   // ⌘Tab
        XCTAssertTrue(systemPassThrough(keyCode: 0x32, command: true))   // ⌘`
        XCTAssertTrue(systemPassThrough(keyCode: 0x31, command: true))   // ⌘Space
        XCTAssertFalse(systemPassThrough(keyCode: 0x30, command: false)) // Tab is the next result
        XCTAssertFalse(systemPassThrough(keyCode: 0x31, command: false)) // Space types / closes the grid
        XCTAssertFalse(systemPassThrough(keyCode: 0x09, command: true))  // ⌘V pastes
    }

    /// No key may be both passed through (the Overview closes) and captured as search input.
    func testPassThroughAndSearchCaptureNeverOverlap() {
        for code in 0 ..< 0x80 {
            for command in [false, true] {
                let captured = searchKey(keyCode: code, shift: false, control: false, option: false,
                                         command: command, chars: "x") != nil
                XCTAssertNotEqual(systemPassThrough(keyCode: code, command: command), captured,
                                  "keyCode \(code) command=\(command)")
            }
        }
    }

    func testOnlyOverviewTogglingChordsActWhileSearching() {
        XCTAssertTrue(allowedWhileSearching(.toggleOverview))   // ⌃⌥Space closes
        XCTAssertTrue(allowedWhileSearching(.toggleSearch))     // ⌃⌥F closes
        XCTAssertTrue(allowedWhileSearching(.toggleHelp))
        XCTAssertFalse(allowedWhileSearching(.overview(.confirm))) // ⌃⌥↩ must not open the hidden grid pick
        XCTAssertFalse(allowedWhileSearching(.slideNext))           // ⌃⌥L must not re-tile mid-search
        XCTAssertFalse(allowedWhileSearching(.cols(2)))
    }

    func testNonPrintableKeysAreSwallowed() {
        XCTAssertEqual(key(0x7B, "\u{F702}"), .ignore)           // ← (private-use function char)
        XCTAssertEqual(key(0x7A, "\u{F704}"), .ignore)           // F1
        XCTAssertEqual(key(0x0E, "\u{05}", control: true), .ignore) // stray ⌃E
    }

    // MARK: isTabButton

    func testTabButtonShapes() {
        // Firefox / Terminal / Finder: radio buttons inside an AXTabGroup.
        XCTAssertTrue(isTabButton(role: "AXRadioButton", subrole: "AXTabButton", parentRole: "AXTabGroup"))
        XCTAssertTrue(isTabButton(role: "AXRadioButton", subrole: nil, parentRole: "AXTabGroup"))
        // Safari: AXTabButtons inside an AXOpaqueProviderGroup (its AXTabGroup holds page content).
        XCTAssertTrue(isTabButton(role: "AXRadioButton", subrole: "AXTabButton", parentRole: "AXOpaqueProviderGroup"))
        // A plain radio button elsewhere (a settings toggle) is not a tab.
        XCTAssertFalse(isTabButton(role: "AXRadioButton", subrole: nil, parentRole: "AXRadioGroup"))
        XCTAssertFalse(isTabButton(role: "AXButton", subrole: "AXTabButton", parentRole: "AXTabGroup"))
    }

    func testNativeWindowTabsAreDetectedByBarPosition() {
        XCTAssertTrue(tabsAreSeparateWindows(barRole: "AXTabGroup", barParentRole: "AXWindow"))      // AppKit tabs
        XCTAssertFalse(tabsAreSeparateWindows(barRole: "AXTabGroup", barParentRole: "AXGroup"))      // Firefox
        XCTAssertFalse(tabsAreSeparateWindows(barRole: "AXOpaqueProviderGroup", barParentRole: "AXWindow")) // Safari
    }

    // MARK: peekPresses

    private let w1: CGWindowID = 1, w2: CGWindowID = 2

    func testPeekPressesSelectedTab() {
        XCTAssertEqual(peekPresses(selected: .tab(window: w1, index: 3), shown: [:], original: [w1: 0]), [w1: 3])
    }

    func testPeekAlreadyShownIsNoop() {
        XCTAssertEqual(peekPresses(selected: .tab(window: w1, index: 3), shown: [w1: 3], original: [w1: 0]), [:])
    }

    func testMovingToAnotherTabInSameWindowDoesNotRestoreFirst() {
        XCTAssertEqual(peekPresses(selected: .tab(window: w1, index: 5), shown: [w1: 3], original: [w1: 0]), [w1: 5])
    }

    func testMovingToAnotherWindowRestoresThePeekedOne() {
        XCTAssertEqual(peekPresses(selected: .tab(window: w2, index: 1), shown: [w1: 3], original: [w1: 0, w2: 4]),
                       [w1: 0, w2: 1])
    }

    func testSelectingAWindowResultRestores() {
        XCTAssertEqual(peekPresses(selected: .window(w1), shown: [w1: 3], original: [w1: 0]), [w1: 0])
    }

    func testCloseRestoresEverything() {
        XCTAssertEqual(peekPresses(selected: nil, shown: [w1: 3, w2: 2], original: [w1: 0, w2: 4]), [w1: 0, w2: 4])
        XCTAssertEqual(peekPresses(selected: nil, shown: [:], original: [w1: 0]), [:])
    }

    // MARK: clickedResult

    func testClickOnTheSelectedResultsWindowPicksTheSelectedResult() {
        // A peeked tab is selected: clicking its card lands on that tab, not the window row.
        let targets: [SearchTarget] = [.window(w1), .tab(window: w1, index: 2), .window(w2)]
        XCTAssertEqual(clickedResult(window: w1, selected: 1, targets: targets), 1)
    }

    func testClickOnAnotherWindowPicksItsOwnRow() {
        let targets: [SearchTarget] = [.tab(window: w1, index: 2), .tab(window: w2, index: 0), .window(w2)]
        XCTAssertEqual(clickedResult(window: w2, selected: 0, targets: targets), 2)
    }

    func testClickOnAWindowWithoutItsOwnRowPicksNothing() {
        // Only another tab of w2 matched: the click centers w2 as it is, it doesn't press that tab.
        let targets: [SearchTarget] = [.window(w1), .tab(window: w2, index: 0)]
        XCTAssertNil(clickedResult(window: w2, selected: 0, targets: targets))
        XCTAssertNil(clickedResult(window: w1, selected: 0, targets: []))         // empty query
        XCTAssertEqual(clickedResult(window: w1, selected: 9, targets: targets), 0) // stale selection
    }

    // MARK: pickTabGroup

    func testPicksGroupWhoseSelectedTabMatchesWindowTitle() {
        // Firefox: real tab bar + the sidebar's own AXTabGroup (verified live, 2026-10-26).
        let tabs = [TabInfo(title: "oolio-group/bookings", selected: false),
                    TabInfo(title: "docs: add booking concept", selected: true)]
        let sidebar = [TabInfo(title: "Bookmarks", selected: false),
                       TabInfo(title: "History", selected: false),
                       TabInfo(title: "Customize sidebar", selected: false)]
        XCTAssertEqual(pickTabGroup([tabs, sidebar], windowTitle: "docs: add booking concept"), 0)
        XCTAssertEqual(pickTabGroup([sidebar, tabs], windowTitle: "docs: add booking concept"), 1)
    }

    func testWindowTitleWithAppSuffixStillMatches() {
        let tabs = [TabInfo(title: "Inbox", selected: true)]
        let other = [TabInfo(title: "Panel", selected: true)]
        XCTAssertEqual(pickTabGroup([other, tabs], windowTitle: "Inbox — Mozilla Firefox"), 1)
    }

    func testUnmatchedTitleFallsBackToTheGroupWithASelectedTab() {
        // Firefox on a New Tab page: window title "Mozilla Firefox" matches no tab (seen live
        // 2026-10-26); the sidebar's buttons are all unselected.
        let tabs = [TabInfo(title: "oolio-group/bookings", selected: false),
                    TabInfo(title: "New Tab", selected: true)]
        let sidebar = [TabInfo(title: "Bookmarks", selected: false),
                       TabInfo(title: "History", selected: false)]
        XCTAssertEqual(pickTabGroup([tabs, sidebar], windowTitle: "Mozilla Firefox"), 0)
        XCTAssertEqual(pickTabGroup([sidebar, tabs], windowTitle: ""), 1)
    }

    func testLoneGroupIsTrusted() {
        XCTAssertEqual(pickTabGroup([[TabInfo(title: "A", selected: false)]], windowTitle: ""), 0)
    }

    func testAmbiguousGroupsYieldNil() {
        let a = [TabInfo(title: "A", selected: true)]
        let b = [TabInfo(title: "B", selected: true)]
        XCTAssertNil(pickTabGroup([a, b], windowTitle: "Something else"))
        XCTAssertNil(pickTabGroup([], windowTitle: "x"))
    }
}
