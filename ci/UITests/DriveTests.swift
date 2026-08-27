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
    /// A fleet row, by the agent name its label starts with.
    ///
    /// `buttons`, not `descendants(matching: .any)`: the attached trees show
    /// each row as `Button, label: '<name>, ...'`, and the `.any` form does not
    /// reliably resolve against SwiftUI's tree -- it is what made the drive
    /// think there was no row to tap and fall through to a coordinate.
    private func row(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", name))
            .firstMatch
    }

    /// The first fleet row lying wholly inside the window.
    ///
    /// Rows are absolutely placed, so `exists` is true for rows scrolled off
    /// either end and their frames go negative. Anything that drives this list
    /// by element has to check the frame itself; XCTest's own `isHittable` will
    /// not do it, because the app puts one gesture surface over the whole list
    /// and hit-testing a row's centre returns that surface rather than the row.
    ///
    /// Width is what separates a row from its own swipe controls: rows span the
    /// full width, RETASK/STOP/KILL are 74-118 pt children of one. Height rules
    /// out the 52 pt `Retired` header, which toggles a section instead of
    /// opening anything.
    private func visibleRow(_ app: XCUIApplication) -> XCUIElement? {
        let screen = app.windows.firstMatch.frame
        return app.buttons.allElementsBoundByIndex.first { button in
            let f = button.frame
            return f.width >= screen.width * 0.8
                && f.height >= 60
                && f.minY >= screen.minY
                && f.maxY <= screen.maxY
                && button.label != "Retired"
        }
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
        attachShot("fleet-shot")
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
        // **The drive has to prove it got in, because everything after this
        // depends on it.** On run 32958131657 the row was not hittable -- the
        // fling above had scrolled it out of view -- the blind coordinate tap
        // opened nothing, and the drive then spent twenty seconds performing
        // "thread" scrolls and five "map" steps against the fleet list. The
        // tree attached at the end of that is unmistakable: `HOTLINE`,
        // `9 AGENTS - 1 BLOCKED`, rows with RETASK/STOP/KILL. No channel was
        // ever open, and nothing said so.
        mark("channel: tap a row")
        // The blocked agent is pinned to the top, so undo the fling first
        // rather than hunting for wherever it ended up.
        at(0.5, 0.30).press(forDuration: 0.05, thenDragTo: at(0.5, 0.85),
                            withVelocity: .fast, thenHoldForDuration: 0.0)
        settle(1.2)
        // Tap a row that is actually on the screen, and do not care which one.
        //
        // `existseq` is not `is on screen here`. FleetLayer places every row
        // absolutely inside a GeometryReader, so a row scrolled past the top is
        // still in the accessibility tree, with a negative frame. Run
        // 33012440901 asked for `hotline-ios` by name, got it, and tapped its
        // centre -- the tree attached to that failure puts the row at
        // {{0, -90}, {420, 116}}, so the touch landed at y = -32, above the
        // window. The element existed, the tap was delivered nowhere, and the
        // channel could not have opened.
        //
        // Naming a specific agent was never worth anything here: any row opens
        // a channel, and which agent it belongs to changes nothing downstream.
        // So take the first full-width row lying wholly inside the window.
        // Two taps are allowed, and which one works is itself the finding.
        //
        // `endTap`'s first branch: a tap while any row is still swiped open
        // closes that row and returns without navigating. That is standard iOS
        // behaviour, not a defect. The swipe steps above are meant to leave
        // nothing open, and whether they do turns on the release velocity of
        // "close it again" landing `.closed` rather than `.openRight`. Running
        // `swipeOutcome` by hand on that drag puts it either side of the line
        // depending on what velocity survives a 0.2 s hold -- x settles at
        // +53.6 against an openRight threshold of 118 * 0.62 = 73.2, so it
        // closes at rest and opens at any residual push.
        //
        // Rather than assume which, tap, look, and report. A channel that needs
        // a second tap means the first was eaten closing a row, and that is
        // worth a line in the log instead of a red run.
        var opened = false
        for attempt in 1...2 {
            if let target = visibleRow(app) {
                mark("  tap \(attempt): visible row \(target.label.prefix(28))")
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                mark("  tap \(attempt): no row lies fully on screen; using a coordinate")
                logTree(app, name: "no-visible-row-\(attempt)")
                at(0.5, 0.44).tap()
            }
            settle(2.0)
            if app.buttons["route-chip"].waitForExistence(timeout: 4) {
                opened = true
                if attempt == 2 {
                    mark("  channel opened on the SECOND tap -- the first was consumed closing a swiped row")
                }
                break
            }
            mark("  tap \(attempt) opened nothing")
        }
        attachTree(app, name: "channel-tree")
        attachShot("channel-shot")

        // `route-chip` is the channel's own chrome, so its absence means no
        // channel -- and it is the element every map step below needs anyway.
        guard opened else {
            mark("  NO CHANNEL after two taps -- thread and map steps skipped")
            // Printed, not only attached. The .xcresult needs a Mac to open and
            // this project is driven from Linux, so a tree that exists only
            // inside the bundle is a tree nobody reads -- which is how the
            // row-frame question stayed open across three runs.
            logTree(app, name: "channel-tree-never-opened")
            XCTFail("channel did not open on either tap; every step after this would have run against the fleet")
            return
        }
        mark("  channel is open")

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
        // **The blind coordinate fallback is gone, and that is the point.**
        // On run 32956648279 the chip was not found, the drive fell back to
        // (0.5, 0.17), and that coordinate opened the *spawn sheet*. The step
        // logged a line nobody read, every later map step then scrubbed a sheet
        // that is not the map, and the run went green having never once opened
        // the screen it claims to exercise -- which is why a map that rendered
        // nothing at all survived this suite.
        //
        // The element was there the whole time: the attached tree for that run
        // has `Button, label: 'Route. 3 phases.'`. What failed was the query.
        // `descendants(matching: .any)` with a label predicate does not
        // reliably resolve against SwiftUI's tree; the chip is a Button, so ask
        // for a Button. The identifier is the real handle -- the label carries
        // a phase count, so matching on it is matching on data.
        let chip = app.buttons["route-chip"].exists
            ? app.buttons["route-chip"]
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Route."))
                         .firstMatch
        guard chip.exists else {
            // Loud, and it does NOT drag anything. A step that cannot reach its
            // target must report that it did not run; dragging somewhere else
            // and calling it a map test is worse than no coverage, because it
            // reads as coverage.
            mark("  NO ROUTE CHIP -- skipping every map step; the map is untested on this run")
            XCTFail("route-chip not found in the channel; the map steps did not run")
            attachTree(app, name: "map-tree-missing-chip")
            return
        }
        mark("  found the route chip: \(chip.label)")
        let chipStart = chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        chipStart.press(forDuration: 0.08,
                        thenDragTo: at(0.5, 0.95),
                        withVelocity: .slow,
                        thenHoldForDuration: 0.2)
        settle(2.0)
        attachTree(app, name: "map-tree")
        attachShot("map-shot")

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

        // ---- 8. rest on a freshly-opened thread -----------------------------
        //
        // **Deliberately after the measured drive, and not part of it.**
        // `out/final.png` is taken by the workflow once the harness has let go,
        // and it is the only frame captured unconditionally -- the filmstrip is
        // best-effort and, contending with the video recorder, landed a frame
        // only every 8 s on run 33088883465. The thread's newest rows went
        // unphotographed on the very run added to photograph them, because the
        // drive starts scrolling 3 ms after the channel opens.
        //
        // A thread opens scrolled to its newest end, so parking here puts the
        // agent's latest prose on the one frame that is always taken.
        mark("rest: re-open a channel so the final frame shows the newest rows")
        for attempt in 1...2 {
            if app.buttons["route-chip"].exists { break }
            if let target = visibleRow(app) {
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                at(0.5, 0.44).tap()
            }
            settle(2.0)
            if attempt == 2, !app.buttons["route-chip"].exists {
                mark("  rest: no channel re-opened; the final frame is the fleet")
            }
        }
        settle(2.5)

        // **Ask the tree, do not photograph it.** Whether the agent's prose
        // arrives whole is a question about the string that reached the view
        // layer, and the filmstrip cannot answer it: it depends on scroll
        // position, a blocked agent's answer card covers the newest rows, and
        // three runs went by without the relevant frame ever being taken.
        //
        // §6's own trap is the tool here. `element.exists` != on screen --
        // rows are in the accessibility tree with off-screen frames -- which is
        // a menace when you are asking "can he tap it" and exactly what is
        // wanted when you are asking "did the whole string get here".
        //
        // Printed, not attached. The .xcresult needs a Mac.
        checkViews(app)

        mark("=== drive ends ===")
        attachTree(app, name: "final-tree")
        attachShot("final-shot")
    }

    // MARK: - The control

    /// Drives Apple's own Settings app, on the same simulator, through the same
    /// recorder and the same gesture primitives as `testDrive`.
    ///
    /// This exists because the drive's frame timings had nothing to be compared
    /// against, and a number with no baseline gets read as an app defect by
    /// default. Corrected for idle and for capture jitter, run 32923724565 came
    /// back at 19% dropped frames spread evenly at 11-20% across every
    /// sustained span, with no gesture standing out -- a flatness that looks
    /// much more like a floor than like anything in this app's code. But
    /// "looks like" is not a measurement, and a CI runner renders the simulator
    /// in software with no GPU to speak of.
    ///
    /// Settings is Apple's code, it is genuinely `UIScrollView`-backed, and it
    /// is smooth on real hardware. So it isolates the one variable that matters:
    /// if the control drops frames at the app's rate, the rate belongs to the
    /// runner and chasing it in this app's views is wasted effort. If the
    /// control is clean and the app is not, the app owns its jank and the
    /// `ThreadView.staged` and `animatableData` suspects are worth the profiler.
    ///
    /// Deliberately not asserting a threshold. This reports; it does not judge,
    /// because what counts as the floor is exactly what is unknown here.
    func testRunnerFloor() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        guard settings.wait(for: .runningForeground, timeout: 30) else {
            mark("control: Settings never came to the foreground -- no baseline this run")
            return
        }
        started = Date()
        settle(2.0)

        func at(_ x: Double, _ y: Double) -> XCUICoordinate {
            settings.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }

        mark("=== control begins ===")

        // The same two gesture shapes the drive leans on, at the same numbers:
        // a slow tracking drag, then a fast one left to decelerate on its own.
        mark("control: six slow drags")
        for _ in 0..<6 {
            at(0.5, 0.78).press(forDuration: 0.08,
                                thenDragTo: at(0.5, 0.34),
                                withVelocity: .slow,
                                thenHoldForDuration: 0.05)
            settle(0.45)
        }

        mark("control: four flings, each left to decelerate")
        for _ in 0..<4 {
            at(0.5, 0.82).press(forDuration: 0.01,
                                thenDragTo: at(0.5, 0.18),
                                withVelocity: .fast,
                                thenHoldForDuration: 0.0)
            settle(1.4)
        }

        mark("=== control ends ===")
    }

    // MARK: - Metrics

    /// The Apple-native measure, attempted honestly.
    ///
    /// There is no signpost metric here, and the reason is worth keeping.
    ///
    /// `XCTOSSignpostMetric.scrollDecelerationHitches` does not exist -- the
    /// build failed on it, which is how it was found. The member was invented,
    /// and it blocked every run for as long as it sat here.
    ///
    /// It was removed rather than renamed. Some near neighbour of that name
    /// almost certainly exists, but picking one without a Mac to compile
    /// against is the same guess that produced the original, and each guess
    /// costs a full macOS run to disprove. Worse, the surrounding comment
    /// already argued the metric could not report anything here: the signpost
    /// metrics only fire for `UIScrollView`-backed surfaces, and this app's
    /// fleet list is absolutely-placed rows over a hand-rolled `scroll` value.
    /// So the correct name would have bought a metric that measures nothing.
    ///
    /// `XCTClockMetric` has no such precondition and does report, so the drag
    /// below is still measured -- just in wall-clock rather than in hitches.
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

        let metrics: [XCTMetric] = [XCTClockMetric()]
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
    /// The tree in the log as well as in the bundle, for the reason given at
    /// the `NO CHANNEL` failure: the .xcresult cannot be opened without a Mac.
    private func logTree(_ app: XCUIApplication, name: String) {
        attachTree(app, name: name)
        print("--- \(name) ---")
        print(app.debugDescription)
        print("--- end \(name) ---")
    }

    private func attachTree(_ app: XCUIApplication, name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The screen itself, saved into the .xcresult beside the tree.
    ///
    /// **This exists because nothing this project builds has ever been looked
    /// at.** The workflow does ask `simctl io` for a recording and a final
    /// frame, but that step produced neither on run 32923724565 -- the
    /// `drive-video` artifact was not created at all, and `if-no-files-found:
    /// warn` meant the run still went green while claiming to have filmed
    /// itself. The .xcresult is the channel that demonstrably works: the
    /// element trees attached the same way came back intact.
    ///
    /// `.keepAlways` is load-bearing. An attachment defaults to
    /// `deleteOnSuccess`, so on a passing run -- the only kind worth comparing
    /// The two views, checked by what each one HIDES.
    ///
    /// Asserting only that the default contains a sent message would pass even
    /// if it also showed the whole firehose, which is the thing the default
    /// exists to remove -- so the absences are the load-bearing half.
    ///
    /// Every marker is a sentinel the stub puts in one place. The first version
    /// of this looked for "pytest" in `app.staticTexts`, which is the entire
    /// accessibility tree: the fleet list is still mounted behind the channel
    /// with every agent's task in it, so a roster row matched and the default
    /// view was reported as leaking tool calls when it was not. §6 says
    /// `element.exists` is not on screen; the same applies to a string.
    private func checkViews(_ app: XCUIApplication) {
        let sentMark = "Deploy is done."
        let toolMark = "ZZTOOLROW"
        let proseMark = "This paragraph exists so a screenshot can prove"

        func seen() -> (sent: Bool, tool: Bool, prose: Bool) {
            let all = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            return (all.contains { $0.contains(sentMark) },
                    all.contains { $0.contains(toolMark) },
                    all.contains { $0.contains(proseMark) })
        }

        let chip = app.buttons["view-chip"]
        guard chip.waitForExistence(timeout: 4) else {
            print("VIEW NOT-FOUND no view-chip; the header row did not render one")
            logTree(app, name: "no-view-chip")
            return
        }

        // §6: an element is in the tree whether or not it is on the screen, and
        // `tap()` taps its frame's centre wherever that lands. `visibleRow`
        // exists because a row once got tapped at y = -32. Report the geometry
        // rather than inferring it from a tap that did nothing.
        let frame = chip.frame
        print("VIEW chip-frame x=\(Int(frame.minX)) y=\(Int(frame.minY)) "
              + "w=\(Int(frame.width)) h=\(Int(frame.height)) "
              + "hittable=\(chip.isHittable) enabled=\(chip.isEnabled)")
        print("VIEW window \(app.windows.firstMatch.frame)")

        let before = seen()
        print("VIEW default sent=\(before.sent) tool=\(before.tool) prose=\(before.prose)")
        print("VIEW default-chip \(chip.label)")

        chip.tap()
        settle(2.0)
        let after = seen()
        print("VIEW full sent=\(after.sent) tool=\(after.tool) prose=\(after.prose)")
        print("VIEW full-chip \(chip.label)")

        // The tap is the one thing here that can fail silently, so say plainly
        // whether the view actually changed rather than leaving it to be
        // inferred from two lines that happen to differ.
        print("VIEW toggled=\(before != after)")
        if before == after {
            // A coordinate tap goes through the same path a finger does and
            // does not care what the element thinks its bounds are. If THIS
            // works and `tap()` did not, the fault is the frame; if neither
            // does, the gesture is not being reached at all.
            chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            settle(2.0)
            let retried = seen()
            print("VIEW retry-coordinate sent=\(retried.sent) tool=\(retried.tool) "
                  + "prose=\(retried.prose) toggled=\(retried != before)")
            print("VIEW retry-chip \(chip.label)")
            if retried == before { logTree(app, name: "view-chip-did-nothing") }
        }

        if after.prose {
            checkProse(app)
        } else {
            print("PROSE SKIPPED the full view never appeared, so there was nothing to measure")
        }

        chip.tap()
        settle(1.0)
    }

    /// The stub injects two `claude` events whose text says what it is proving.
    /// This reports on the one that matters: full length, paragraph breaks
    /// intact, no ellipsis. See `ci/stub/daemon.py`.
    private func checkProse(_ app: XCUIApplication) {
        let head = "This paragraph exists so a screenshot can prove"
        let tail = "the fix did not reach the device."
        // `first(where:)` spelled out. `Array.first` is also a property, and a
        // trailing closure on the next line binds to that instead -- which is
        // what failed the build on run 33094103028.
        let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        guard let text = labels.first(where: { $0.contains(head) }) else {
            print("PROSE NOT-FOUND no static text contains the marker")
            return
        }
        let breaks = text.filter { $0 == "\n" }.count
        print("PROSE chars=\(text.count) newlines=\(breaks) "
              + "endsWithTail=\(text.hasSuffix(tail)) ellipsis=\(text.contains("\u{2026}"))")
    }

    private func attachShot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
