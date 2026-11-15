import Testing
@testable import MossCore

@Suite("Parsing")
struct ParsingTests {
    @Test(arguments: [
        "workspace 3", "workspace next", "workspace previous", "workspace last", "workspace empty", "workspace +1", "workspace mail",
        "workspace scratchpad:notes", "workspace scratchpad", "move-to-workspace 3 app:^kitty$", "send-to-workspace scratchpad",
        "bring-workspace 2", "rename-workspace 3 Mail", "scratchpad", "scratchpad notes",
        "float", "float on", "float off focused", "fullscreen", "maximize on", "keep-size", "pin off", "center", "tag +work", "tag -work id:0x2a",
        "bring-to-front", "focus left", "focus last", "focus-window title:^Inbox$", "cycle", "cycle previous tiled", "move down",
        "move-to-display next", "swap up", "swap next", "resize to 50% 50%", "resize by 10 -10", "position to 0 0", "split-ratio 0.6",
        "split-ratio +0.1", "layout stack", "layout default", "layout toggle stack", "focus-display built-in", "move-workspace-to-display left 3", "swap-workspaces left right",
        "tabs", "tab next", "tab 2", "join-tabs left", "leave-tabs", "move-tab previous", "mode resize", "mode default",
        "run open -a Terminal", "run [float, size=60% 70%] open -a Terminal", "close", "close app:Safari", "quit-app", "signal TERM",
        "signal KILL app:^kitty$", "send-keys cmd-c", "send-keys ctrl-shift-tab app:^com.apple.Safari$", "emit hello there",
        "palette", "overview", "overview previous", "pause", "pause on", "reload", "quit",
        "flip-split", "preselect right", "promote", "swap-main", "main-count +1", "stack-side center", "main-size 0.6", "rotate next",
        "column next", "column-width next", "column-width all 0.5", "move-column left", "join-column right", "leave-column",
        "fit to-end", "scroll -200", "reveal", "scroll-to toggle", "lock-view on",
    ])
    func actionsRoundTrip(text: String) throws {
        let action = try Action(parsing: text)
        #expect(try Action(parsing: action.description) == action)
    }

    @Test func unknownActionSuggestsAName() {
        #expect(throws: ActionError.unknownAction("worksapce", suggestion: "workspace")) {
            try Action(parsing: "worksapce 1")
        }
    }

    @Test func invalidArgumentsAreReported() {
        #expect(throws: ActionError.self) { try Action(parsing: "focus sideways") }
        #expect(throws: ActionError.self) { try Action(parsing: "workspace") }
        #expect(throws: ActionError.self) { try Action(parsing: "resize 10 10") }
        #expect(throws: ActionError.self) { try Action(parsing: "center now") }
        #expect(throws: ActionError.self) { try Action(parsing: "run [float, wobble] open -a Terminal") }
        #expect(throws: ActionError.self) { try Action(parsing: "emit") }
        #expect(throws: ActionError.self) { try Action(parsing: "scratchpad a b") }
    }

    @Test func signalsByNumberOrName() throws {
        #expect(try Action(parsing: "signal SIGKILL") == .signal(9, nil))
        #expect(try Action(parsing: "signal term") == .signal(15, nil))
        #expect(try Action(parsing: "signal USR1 id:0x2a") == .signal(30, .id(WindowID(0x2A))))
        #expect(throws: ActionError.self) { try Action(parsing: "signal 99") }
    }

    @Test func sentKeys() throws {
        #expect(try Action(parsing: "send-keys cmd-c") == .sendKeys(KeyChord(modifiers: .command, key: .key("c")), nil))
        #expect(throws: ActionError.self) { try Action(parsing: "send-keys cmd-left-drag") }
        #expect(throws: ActionError.self) { try Action(parsing: "send-keys mod-c") }
    }

    @Test func runRules() throws {
        let (rules, command) = try Action.splitRunRules("[float, size=60% 70%, workspace=3, silent] open -a Terminal")
        #expect(command == "open -a Terminal")
        #expect(rules == [.float, .size(.percent(60), .percent(70)), .workspace(.id(3), silent: true)])
    }

    @Test func chords() throws {
        let chord = try KeyChord(parsing: "mod-shift-left", mainKey: .capsLock)
        #expect(chord.modifiers == [.capsLock, .shift])
        #expect(chord.key == .key("left"))
        #expect(chord.description(mainKey: .capsLock) == "mod-shift-left")
        #expect(chord.description(mainKey: .option) == "caps-shift-left")
        #expect(try KeyChord(parsing: "cmd-alt-page-up").key == .key("page_up"))
        #expect(try KeyChord(parsing: "ctrl-minus").key == .key("-"))
        #expect(try KeyChord(parsing: "hyper-t").modifiers == .hyper)
        #expect(try KeyChord(parsing: "mod-left-drag", mainKey: .option) == KeyChord(modifiers: .option, key: .drag(.left)))
        #expect(try KeyChord(parsing: "alt-scroll-down").key == .scroll(.down))
        #expect(throws: KeyBindingError.mainKeyUnavailable) { try KeyChord(parsing: "mod-q") }
        #expect(throws: KeyBindingError.self) { try KeyChord(parsing: "mod-squiggle", mainKey: .option) }
    }

    @Test func hyperChordsAreWrittenAsHyper() throws {
        let chord = try KeyChord(parsing: "hyper-h", mainKey: .option)
        #expect(chord.description(mainKey: .option) == "hyper-h")
        #expect(try KeyChord(parsing: chord.description(mainKey: .option), mainKey: .option) == chord)
        #expect(try KeyChord(parsing: "mod-h", mainKey: .hyper).description(mainKey: .hyper) == "mod-h")
        #expect(try KeyChord(parsing: "mod-shift-h", mainKey: .option).description(mainKey: .option) == "mod-shift-h")
    }

    @Test func modifiers() throws {
        #expect(try Modifiers(parsing: "ctrl-alt") == [.control, .option])
        #expect(try Modifiers(parsing: "hyper") == .hyper)
        #expect(Modifiers.hyper.description == "hyper")
        #expect(Modifiers.hyper.union(.function).description == "hyper-fn")
        #expect(Modifiers.meh.description == "ctrl-alt-shift")
        #expect(Modifiers([.command, .shift, .control]).description == "ctrl-shift-cmd")
        #expect(throws: KeyBindingError.unknownModifier("super")) { try Modifiers(parsing: "super") }
    }

    @Test func selectors() throws {
        #expect(try WorkspaceSelector(parsing: "name:next").description == "name:next")
        #expect(try WorkspaceSelector(parsing: "mail") == .named("mail"))
        #expect(try WindowSelector(parsing: "Safari") == .app(try Pattern.compile("Safari")))
        #expect(try MonitorSelector(parsing: "main") == .main)
        #expect(throws: ActionError.self) { try WindowSelector(parsing: "class:Safari") }
    }

    @Test func colors() {
        #expect(ColorNotation.parse("#ff8800") == Color(rgba: 0xff88_00ff))
        #expect(ColorNotation.parse("#ff880080") == Color(rgba: 0xff88_0080))
        #expect(ColorNotation.parse("#f80") == Color(rgba: 0xff88_00ff))
        #expect(ColorNotation.parse("accent(0.5)")?.alpha == 0.5)
        #expect(ColorNotation.parse("clear") == .clear)
        #expect(ColorNotation.parse("rgba(ff8800ee)") == nil)
        let gradient = ColorNotation.parseGradient("#ff9500 #ff2d55 45deg")
        #expect(gradient?.colors.count == 2)
        #expect(gradient?.description == "#ff9500 #ff2d55 45deg")
    }

    @Test func windowRules() throws {
        let rules = try WindowRule.rules(from: [("if.app", "^org\\.mozilla\\.firefox$"), ("if.title", "Mail"), ("workspace", "2"), ("silent", "true"), ("float", "true")])
        #expect(rules.map(\.effect) == [.workspace(.id(2), silent: true), .float])
        #expect(rules[0].conditions.count == 2)

        var window = Window(id: 1, properties: properties("org.mozilla.firefox", title: "Inbox - Mail"), workspace: .numbered(1), isFloating: false, floatingFrame: .zero)
        #expect(rules[0].matches(window, focused: false))
        window.properties.title = "News"
        #expect(!rules[0].matches(window, focused: false))

        #expect(throws: ActionError.self) { try WindowRule.rules(from: [("float", "true")]) }
        #expect(throws: ActionError.self) { try WindowRule.rules(from: [("if.app", "x")]) }
        #expect(throws: ActionError.self) { try WindowRule.rules(from: [("if.class", "x"), ("float", "true")]) }
        #expect(try WindowRule.rules(from: [("if.app", "x"), ("fullscreen", "false")]).isEmpty)
    }

    @Test(arguments: [
        [("dim", "false")], [("corner-radius", "4")], [("keep-focus", "true")], [("min-size", "300 200")], [("max-size", "800 600")],
        [("tabs", "own")], [("tabs", "never")], [("tag", "work")], [("border-color", "#ff8800 #444444")], [("workspace", "mail"), ("silent", "true")],
        [("size", "60% 70%")], [("position", "10 20")], [("focus-on-open", "false")], [("display", "built-in")],
    ])
    func ruleEffectsRoundTrip(entries: [(String, String)]) throws {
        let effects = try WindowRule.Effect.effects(from: entries)
        #expect(effects.count == 1)
        #expect(try WindowRule.Effect.effects(from: effects[0].entries) == effects)
    }

    @Test func tagConditions() throws {
        let rule = try WindowRule.rules(from: [("if.tag", "term"), ("border-width", "4")])[0]
        var window = Window(id: 1, properties: properties(), workspace: .numbered(1), isFloating: false, floatingFrame: .zero)
        #expect(!rule.matches(window, focused: false))
        window.tags = ["term"]
        #expect(rule.matches(window, focused: false))
    }

    @Test func workspaceRules() throws {
        let rule = try WorkspaceRule(workspace: .numbered(3), entries: [("display", "DP-1"), ("default", "true"), ("gaps", "2 4"), ("persistent", "true"), ("name", "Mail")])
        #expect(rule.display == .name("DP-1"))
        #expect(rule.gaps == Insets(top: 2, right: 4, bottom: 2, left: 4))
        #expect(rule.isPersistent && rule.isDefault)
        #expect(try WorkspaceRule(workspace: .numbered(3), entries: rule.entries) == rule)
        #expect(throws: ActionError.self) { try WorkspaceRule(workspace: .numbered(3), entries: [("monitor", "DP-1")]) }
    }

    @Test func bezierCurves() {
        #expect(abs(BezierCurve.linear.value(at: 0.25) - 0.25) < 0.001)
        #expect(BezierCurve.easeOutQuint.value(at: 0) == 0)
        #expect(BezierCurve.easeOutQuint.value(at: 1) == 1)
        // easeOutQuint covers most of the distance early.
        #expect(BezierCurve.easeOutQuint.value(at: 0.3) > 0.8)
        #expect(abs(BezierCurve(0.42, 0, 0.58, 1).value(at: 0.5) - 0.5) < 0.001)
    }

    @Test func insetsShorthand() {
        #expect(Insets(cssNotation: "5") == Insets(all: 5))
        #expect(Insets(cssNotation: "1 2 3 4") == Insets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(Insets(cssNotation: "a") == nil)
    }
}
