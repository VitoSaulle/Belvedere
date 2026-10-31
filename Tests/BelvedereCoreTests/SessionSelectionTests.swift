import Testing
@testable import BelvedereCore

@Suite struct SessionSelectionTests {
    private let order = ["a", "b", "c", "d"]

    @Test func commandTogglesOneByOne() {
        var s = SessionSelection()
        s.toggle("a")
        s.toggle("c")
        #expect(s.ids == ["a", "c"])
        s.toggle("a")
        #expect(s.ids == ["c"])
    }

    @Test func shiftExtendsInBothDirectionsFromTheLastChoice() {
        var s = SessionSelection()
        s.toggle("b")
        s.extend(to: "d", in: order)
        #expect(s.ids == ["b", "c", "d"])
        var up = SessionSelection()
        up.toggle("c")
        up.extend(to: "a", in: order)
        #expect(up.ids == ["a", "b", "c"])
    }

    @Test func shiftWithoutAnAnchorSelectsOnlyThatSession() {
        var s = SessionSelection()
        s.extend(to: "b", in: order)
        #expect(s.ids == ["b"])
    }

    @Test func selectAllTakesWhatIsVisible() {
        var s = SessionSelection()
        s.toggle("z")
        s.selectAll(order)
        #expect(s.ids == Set(order))
    }

    @Test func menuActsOnTheSelectionOnlyFromInsideIt() {
        var s = SessionSelection()
        s.toggle("a")
        s.toggle("b")
        #expect(s.targets(for: "a") == ["a", "b"])
        #expect(s.targets(for: "c") == ["c"])
    }
}
