import Testing
@testable import BelvedereCore

@Suite struct ScrollFollowTests {
    private func spot(_ offset: Double, viewport: Double = 500, content: Double = 2000) -> ScrollSpot {
        ScrollSpot(offset: offset, viewport: viewport, content: content)
    }

    @Test func scrollingUpStopsFollowing() {
        #expect(!ScrollSpot.following(true, from: spot(1500), to: spot(1200)))
    }

    @Test func growingContentKeepsFollowing() {
        #expect(ScrollSpot.following(true, from: spot(1500), to: spot(1500, content: 2600)))
    }

    @Test func backAtTheBottomFollowsAgain() {
        #expect(ScrollSpot.following(false, from: spot(1200), to: spot(1490)))
    }

    @Test func readingHigherUpWhileTextArrivesStaysPut() {
        #expect(!ScrollSpot.following(false, from: spot(800), to: spot(800, content: 2400)))
    }

    @Test func resizingTheWindowIsNotAScrollUp() {
        #expect(ScrollSpot.following(true, from: spot(1500), to: spot(1300, viewport: 600, content: 2100)))
    }
}
