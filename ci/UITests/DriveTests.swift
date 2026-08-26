import XCTest

/// Drives the app on a booted simulator so its motion can be watched and
/// measured instead of reasoned about.
///
/// Two things shape every line of this file.
///
/// **There are no accessibility identifiers in the app.** There are
/// accessibility *labels* -- "Back to the fleet", "Server address",
/// "Route. N phases.", and a per-row spoken label that starts with the agent's
/// name -- and those are used where they exist. Everything else is driven by
/// coordinate, which is also the honest way to drive this particular app.
///
/// **Almost nothing here is UIKit.** The fleet list is a `GeometryReader` full
/// of absolutely-placed rows with a hand-rolled `scroll` value and a single
/// `DragGesture(minimumDistance: 0)` that arbitrates tap vs scroll vs row-swipe
/// behind an 8 pt hysteresis. So `XCUIElementTypeScrollView` matches nothing,
/// `swipeUp()`'s system parameters are not guaranteed to cross this app's
/// thresholds, and `press(forDuration:thenDragTo:withVelocity:)` is the only
/// primitive that reliably does. The numbers below (8 pt lock, 74 pt pull,
/// 1100 pt/s fling) are the app's own, read out of FleetLayer.swift.
///
/// The drive is deliberately forgiving: a step that cannot find its target logs
/// and moves on rather than aborting, because the video of the steps that DID
/// work is the point. `testLaunches` is the one hard assertion -- if the app
/// never gets past the setup screen, CI must go red.
final class DriveTests: XCTestCase {

    /// The stub daemon runs on the host's loopback, which the simulator shares.
    static let server = ProcessInfo.processInfo.environment["HOTLINE_STUB"] ?? "127.0.0.1:8789"

    private var started = Date()

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - Launch

    /// `-hotline.server <addr>` lands in `NSArgumentDomain`, which
    /// `UserDefaults.standard.string(forKey: "hotline.server")` reads first --
    /// so `Settings/Server.swift` is configured with no source change at all.
    /// The typed fallback exists because a key containing a dot is the sort of
    /// thing that works everywhere until it does not.
    @discardableResult
    private func launched(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hotline.server", Self.server, "-AppleLanguages", "(en)"] + extra
        app.launch()
        started = Date()

        let connect = app.buttons["Connect"]
        if connect.waitForExistence(timeout: 4) {
            mark("setup screen shown -- argument domain did not take, typing the address")
            let field = app.textFields["100.x.y.z or archserver"]
            if field.waitForExistence(timeout: 4) {
                field.tap()
                field.typeText(Self.server)
                app.buttons["Connect"].tap()
            }
        } else {
            mark("went straight to the shell: launch argument configured the server")
        }
        return app
    }

    private func mark(_ what: String) {
        let t = Date().timeIntervalSince(started)
        print(String(format: "MARK %7.3f  %@", t, what))
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        // Nothing here is instantaneous and the fleet arbiter is inert while
        // `nav >= 0.02`, so every step pays for the transition before the next.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    /// The first row's spoken label begins with the agent's name; matching on
    /// `label BEGINSWITH` is the only stable handle the app offers.
    private func row(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", name))
            .firstMatch
    }

    // MARK: - The one hard assertion

    func testLaunches() throws {
        let app = launched()
        // Any agent row from the fixtures proves the app booted, reached the
        // stub, decoded the roster and laid out a list.
        let anyRow = row(app, named: "hotline-ios")
        XCTAssertTrue(
            anyRow.waitForExistence(timeout: 30),
            "no agent row from the stub daemon after 30 s -- the app never got a roster it could render"
        )
        mark("roster rendered")
        attachTree(app, name: "fleet-tree")
    }

    // MARK: - The drive

    func testDrive() throws {
        let app = launched()
        _ = row(app, named: "hotline-ios").waitForExistence(timeout: 30)
        settle(1.5)

        // The stub serves a blocked agent, and a blocked agent on a cold launch
        // is exactly what `Shell.launch`'s `autoOpenIfOwed(.cold)` exists for --
        // so the app may already have flown itself into that channel. Every
        // fleet gesture below is behind `guard nav < 0.02` and would silently do
        // nothing. Get back to the list first, and say so, because "it
        // auto-opened" is itself worth knowing.
        let backAtStart = app.buttons["Back to the fleet"]
        if backAtStart.waitForExistence(timeout: 3) {
            mark("cold auto-open fired: a channel is already open, backing out")
            backAtStart.tap()
            settle(2.0)
        } else {
            mark("no cold auto-open; starting on the fleet list")
        }

        mark("=== drive begins ===")

        func at(_ x: Double, _ y: Double) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }

        // ---- 1. slow scroll -------------------------------------------------
        // Well past the 8 pt axis lock, slow enough that the spring in
        // `settle(...)` is following the finger rather than being thrown.
        mark("scroll: three slow drags up")
        for _ in 0..<3 {
            at(0.5, 0.78).press(forDuration: 0.08,
                                thenDragTo: at(0.5, 0.34),
                                withVelocity: .slow,
                                thenHoldForDuration: 0.05)
            settle(0.45)
        }

        mark("scroll: two slow drags back down")
        for _ in 0..<2 {
            at(0.5, 0.34).press(forDuration: 0.08,
                                thenDragTo: at(0.5, 0.78),
                                withVelocity: .slow,
                                thenHoldForDuration: 0.05)
            settle(0.45)
        }

        // ---- 2. the fling ---------------------------------------------------
        // This is the one Bogdan says looks wrong. `.fast` is XCUITest's
        // highest preset; the app commits a fling past 1100 pt/s.
        mark("fling: fast flick up, let it decelerate")
        at(0.5, 0.82).press(forDuration: 0.01,
                            thenDragTo: at(0.5, 0.18),
                            withVelocity: .fast,
                            thenHoldForDuration: 0.0)
        settle(2.2)   // long, so the whole deceleration curve is on the video

        mark("fling: fast flick down, into the top rubber band")
        at(0.5, 0.22).press(forDuration: 0.01,
                            thenDragTo: at(0.5, 0.86),
                            withVelocity: .fast,
                            thenHoldForDuration: 0.0)
        settle(2.2)

        // ---- 3. row swipe ---------------------------------------------------
        // Horizontal past the 8 pt lock. Deliberately stops short of the
        // commit distance so the controls rest open and can be seen, rather
        // than firing stop/kill against the stub.
        mark("swipe: drag a row left to rest the controls open")
        at(0.72, 0.44).press(forDuration: 0.06,
                             thenDragTo: at(0.30, 0.44),
                             withVelocity: .slow,
                             thenHoldForDuration: 0.3)
        settle(1.2)
        mark("swipe: close it again")
        at(0.30, 0.44).press(forDuration: 0.06,
                             thenDragTo: at(0.78, 0.44),
                             withVelocity: .slow,
                             thenHoldForDuration: 0.2)
        settle(1.2)

        // ---- 4. open a channel ----------------------------------------------
        // A synthetic tap never travels 8 pt, so the arbiter resolves it as a
        // tap and `Shell.enter` flies the hero title across.
        mark("channel: tap a row")
        let target = row(app, named: "hotline-ios")
        if target.exists && target.isHittable {
            target.tap()
        } else {
            mark("  (row not hittable, tapping its coordinate instead)")
            at(0.5, 0.44).tap()
        }
        settle(2.0)
        attachTree(app, name: "channel-tree")

        // ---- 5. scroll the thread -------------------------------------------
        // ThreadView ignores anything starting in the left 44 pt, which belongs
        // to BackStrip -- so every thread drag starts at x = 0.55.
        mark("thread: slow scroll up")
        for _ in 0..<3 {
            at(0.55, 0.76).press(forDuration: 0.08,
                                 thenDragTo: at(0.55, 0.30),
                                 withVelocity: .slow,
                                 thenHoldForDuration: 0.05)
            settle(0.5)
        }
        mark("thread: fling")
        at(0.55, 0.80).press(forDuration: 0.01,
                             thenDragTo: at(0.55, 0.22),
                             withVelocity: .fast,
                             thenHoldForDuration: 0.0)
        settle(2.0)

        mark("thread: pull past the top (74 pt arms 'load older')")
        at(0.55, 0.28).press(forDuration: 0.1,
                             thenDragTo: at(0.55, 0.70),
                             withVelocity: .slow,
                             thenHoldForDuration: 0.5)
        settle(1.5)

        // ---- 6. the map ------------------------------------------------------
        // The ROUTE chip opens the map by DOWNWARD DRAG, not by tap:
        // progress = dy / viewport * 1.35, so ~74% of the height reaches 1.
        mark("map: drag the ROUTE chip down to open")
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Route."))
            .firstMatch
        let chipStart: XCUICoordinate
        if chip.exists {
            mark("  found the route chip by label: \(chip.label)")
            chipStart = chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        } else {
            mark("  no route chip by label; using the header band coordinate")
            chipStart = at(0.5, 0.17)
        }
        chipStart.press(forDuration: 0.08,
                        thenDragTo: at(0.5, 0.95),
                        withVelocity: .slow,
                        thenHoldForDuration: 0.2)
        settle(2.0)
        attachTree(app, name: "map-tree")

        mark("map: scrub the timeline")
        for _ in 0..<3 {
            at(0.5, 0.70).press(forDuration: 0.06,
                                thenDragTo: at(0.5, 0.36),
                                withVelocity: .slow,
                                thenHoldForDuration: 0.05)
            settle(0.6)
        }
        mark("map: scrub back")
        at(0.5, 0.36).press(forDuration: 0.06,
                            thenDragTo: at(0.5, 0.74),
                            withVelocity: .slow,
                            thenHoldForDuration: 0.05)
        settle(1.0)

        mark("map: drag the blind back up to close (grabber lives above y<90)")
        at(0.5, 0.10).press(forDuration: 0.08,
                            thenDragTo: at(0.5, 0.02),
                            withVelocity: .slow,
                            thenHoldForDuration: 0.1)
        settle(1.5)

        // ---- 7. back to the fleet -------------------------------------------
        mark("back: interactive scrub from the left edge")
        at(0.02, 0.5).press(forDuration: 0.08,
                            thenDragTo: at(0.75, 0.5),
                            withVelocity: .slow,
                            thenHoldForDuration: 0.1)
        settle(2.0)

        let back = app.buttons["Back to the fleet"]
        if back.exists {
            mark("back: still on the channel, tapping 'Back to the fleet'")
            back.tap()
            settle(2.0)
        }

        mark("=== drive ends ===")
        attachTree(app, name: "final-tree")
    }

    // MARK: - Metrics

    /// The Apple-native measure, attempted honestly.
    ///
    /// `XCTOSSignpostMetric.scrollDecelerationHitches` only reports if the
    /// scrolling surface is `UIScrollView`-backed and emits the system's
    /// scroll signposts. This app's fleet list is not a `UIScrollView` -- it is
    /// absolutely-placed rows over a hand-rolled `scroll` value -- so the
    /// expectation is that this yields nothing. It is run anyway, because
    /// "we tried it and it reported nothing" is a result and a guess is not.
    ///
    /// `XCTApplicationLaunchMetric` and `XCTClockMetric` do not have that
    /// precondition and will report.
    func testLaunchMetric() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hotline.server", Self.server]
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            app.terminate()
        }
    }

    func testScrollHitchMetric() throws {
        let app = launched()
        _ = row(app, named: "hotline-ios").waitForExistence(timeout: 30)
        settle(1.0)

        let metrics: [XCTMetric] = [
            XCTOSSignpostMetric.scrollDecelerationHitches,
            XCTClockMetric(),
        ]
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 3

        measure(metrics: metrics, options: options) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                .press(forDuration: 0.01,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)),
                       withVelocity: .fast,
                       thenHoldForDuration: 0.0)
            settle(1.8)
            stopMeasuring()
            // Put the list back where it started so each iteration measures the
            // same motion rather than a progressively shorter one.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
                .press(forDuration: 0.01,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                       withVelocity: .fast,
                       thenHoldForDuration: 0.0)
            settle(1.2)
        }
    }

    // MARK: - Diagnostics

    /// The element tree, saved into the .xcresult. Without identifiers this is
    /// the only way to find out afterwards what was actually on screen when a
    /// step missed.
    private func attachTree(_ app: XCUIApplication, name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
