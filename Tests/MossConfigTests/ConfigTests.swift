import Foundation
import Testing
import MossCore
@testable import MossConfig

func evaluate(_ text: String, files: [String: String] = [:]) -> EvaluatedConfig {
    var all = files
    all["/config/moss.toml"] = text
    return ConfigEvaluator(fileSystem: MemoryFileSystem(all)).evaluate(fileAt: URL(fileURLWithPath: "/config/moss.toml"))
}

@Suite("TOML")
struct TOMLTests {
    func value(_ text: String) -> TOMLValue? {
        TOMLDocument(text: "key = \(text)\n").value(at: ["key"])
    }

    @Test func values() {
        #expect(value(#""a \"quoted\" word\tand\u00e9""#) == .string("a \"quoted\" word\tandé"))
        #expect(value("'C:\\no\\escapes'") == .string("C:\\no\\escapes"))
        #expect(value("1_000") == .integer(1000))
        #expect(value("0xff") == .integer(255))
        #expect(value("-0.5") == .float(-0.5))
        #expect(value("5e-1") == .float(0.5))
        #expect(value("true") == .boolean(true))
        #expect(value("[1, 2.5, \"three\"]") == .array([.integer(1), .float(2.5), .string("three")]))
        #expect(value("{ action = \"focus left\", repeat = true }") == .table([TOMLPair("action", .string("focus left")), TOMLPair("repeat", .boolean(true))]))
    }

    @Test func multilineValues() {
        let document = TOMLDocument(text: "list = [\n  1,\n  2, # two\n]\ntext = \"\"\"\nfirst\nsecond\"\"\"\n")
        #expect(document.value(at: ["list"]) == .array([.integer(1), .integer(2)]))
        #expect(document.value(at: ["text"]) == .string("first\nsecond"))
        #expect(document.syntaxErrors.isEmpty)
    }

    @Test func tablesAndDottedKeys() {
        let document = TOMLDocument(text: "a.b = 1\n\n[layout]\nbsp.default-ratio = 0.6\n\"quoted key\" = 2\n\n[[rules]]\nif.app = \"x\"\n\n[[rules]]\nfloat = true\n")
        #expect(document.value(at: ["a", "b"]) == .integer(1))
        #expect(document.value(at: ["layout", "bsp", "default-ratio"]) == .float(0.6))
        #expect(document.value(at: ["layout", "quoted key"]) == .integer(2))
        #expect(document.arrayTables(["rules"]).count == 2)
        #expect(document.arrayTables(["rules"])[1].arrayIndex == 1)
    }

    @Test func syntaxErrorsNameTheirLineAndReadingGoesOn() {
        let document = TOMLDocument(text: "a = 1\nb = \nc = \"open\nd = 2024-01-01\ne = 5\n")
        #expect(document.syntaxErrors.map(\.line) == [1, 2, 3])
        #expect(document.value(at: ["e"]) == .integer(5))
        #expect(document.syntaxErrors[2].message.contains("dates"))
    }

    @Test func conflictsAreReported() {
        let (_, errors) = TOMLDocument(text: "a = 1\na = 2\n[t]\nx = 1\n[t]\ny = 2\n").tree()
        #expect(errors.map(\.line) == [1, 4])
    }

    @Test func textRoundTripsExactly() {
        let text = "# Moss\n\n[layout]   # how windows tile\ngaps = 5 # points\n\n\n[shortcuts]\nmod-q = 'run open -na Terminal'\n"
        #expect(TOMLDocument(text: text).text == text)
        #expect(TOMLDocument(text: "a = 1").text == "a = 1")
    }

    @Test func settingAValueKeepsItsCommentAndIndent() {
        var document = TOMLDocument(text: "[layout]\n  gaps = 5 # points\n")
        document.setValue(.integer(8), at: ["layout", "gaps"])
        #expect(document.text == "[layout]\n  gaps = 8 # points\n")
    }

    @Test func settingANewValueJoinsItsTable() {
        var document = TOMLDocument(text: "[layout]\ngaps = 5\n\n[borders]\nwidth = 1\n")
        document.setValue(.integer(20), at: ["layout", "margins"])
        #expect(document.text == "[layout]\ngaps = 5\nmargins = 20\n\n[borders]\nwidth = 1\n")
    }

    @Test func settingAValueAddsItsTable() {
        var document = TOMLDocument(text: "[layout]\ngaps = 5\n")
        document.setValue(.string("#ff8800"), at: ["borders", "active"])
        #expect(document.value(at: ["borders", "active"]) == .string("#ff8800"))
        #expect(document.text.hasSuffix("[borders]\nactive = \"#ff8800\"\n"))
    }

    @Test func settingADottedValueEditsIt() {
        var document = TOMLDocument(text: "layout.gaps = 5\n")
        document.setValue(.integer(3), at: ["layout", "gaps"])
        #expect(document.text == "layout.gaps = 3\n")
    }

    @Test func removingAValueRemovesItsLine() {
        var document = TOMLDocument(text: "[layout]\ngaps = 5\nmargins = 20\n")
        document.removeValue(at: ["layout", "gaps"])
        #expect(document.text == "[layout]\nmargins = 20\n")
    }

    @Test func arraysOfTablesAreEdited() {
        var document = TOMLDocument(text: "[[rules]]\nif.app = \"a\"\nfloat = true\n")
        document.appendArrayTable(["rules"], entries: [(["if", "app"], .string("b")), (["workspace"], .string("2"))])
        #expect(document.arrayTables(["rules"]).count == 2)
        document.replaceArrayTable(["rules"], at: 0, entries: [(["if", "app"], .string("c")), (["pin"], .boolean(true))])
        #expect(document.value(at: ["rules"]) == nil)
        #expect(document.arrayTables(["rules"])[0].entries.map(\.key) == [["if", "app"], ["pin"]])
        document.removeArrayTable(["rules"], at: 0)
        #expect(document.arrayTables(["rules"]).map { Declarations.entries(of: $0).map(\.value) } == [["b", "2"]])
    }

    @Test func tablesAreReplacedAndRemoved() {
        var document = TOMLDocument(text: "[workspaces.3]\nname = \"Mail\"\n\n[borders]\nwidth = 1\n")
        document.setTable(["workspaces", "3"], entries: [(["name"], .string("Web")), (["persistent"], .boolean(true))])
        #expect(document.text.hasPrefix("[workspaces.3]\nname = \"Web\"\npersistent = true\n"))
        document.removeTable(["workspaces", "3"])
        #expect(document.text == "[borders]\nwidth = 1\n")
    }

    @Test func keysAreQuotedOnlyWhenNeeded() {
        #expect(TOMLValue.key("mod-shift-1") == "mod-shift-1")
        #expect(TOMLValue.key("mod-shift-=") == "\"mod-shift-=\"")
        #expect(TOMLValue.string("say \"hi\"\n").text == #""say \"hi\"\n""#)
        #expect(TOMLValue.float(2).text == "2.0")
    }
}

@Suite("Configuration")
struct ConfigTests {
    @Test func defaultConfigurationIsClean() {
        let config = evaluate(DefaultConfiguration.text)
        #expect(config.diagnostics == [])
        #expect(config.settings.keyboard.mainKey == .capsLock)
        #expect(config.settings.keyboard.capsLock == .hyper)
        #expect(config.bindings.contains { $0.chord == KeyChord(modifiers: .capsLock, key: .key("h")) && $0.action == .focus(.left) })
        #expect(config.bindings.contains { $0.chord == KeyChord(modifiers: [.capsLock, .shift], key: .key("h")) && $0.action == .move(.left) })
        #expect(config.bindings.contains { $0.chord == KeyChord(modifiers: [.capsLock, .option], key: .key("l")) && $0.options.contains(.repeats) })
        #expect(config.bindings.contains { $0.chord == KeyChord(modifiers: .option, key: .key("1")) && $0.action == .workspace(.id(1)) })
        #expect(config.bindings.contains { $0.chord == KeyChord(modifiers: [.option, .shift], key: .key("1")) })
        #expect(config.bindings.contains { $0.trigger == .drag(.left) && $0.command == .drag(.move) })
        // Which applications to open is the user's choice.
        #expect(!config.bindings.contains { if case .run = $0.action { true } else { false } })
    }

    @Test func optionsReadFromTablesAndDottedKeys() {
        let config = evaluate("""
        animation.enabled = false

        [layout]
        style = "stack"
        gaps = [4, 8]
        margins = 10
        stack.main-size = 0.6

        [layout.bsp]
        new-window-side = "after"

        [borders]
        active = "#ff8800 #8800ff 45deg"

        [focus]
        follows-mouse = false
        """)
        #expect(config.diagnostics == [])
        #expect(!config.settings.animation.isEnabled)
        #expect(config.settings.layout.style == .stack)
        #expect(config.settings.layout.gaps == Insets(top: 4, right: 8, bottom: 4, left: 8))
        #expect(config.settings.layout.margins == Insets(all: 10))
        #expect(config.settings.layout.stack.mainSize == 0.6)
        #expect(config.settings.layout.bsp.newWindowSide == .after)
        #expect(config.settings.borders.active.colors.count == 2)
        #expect(!config.settings.focus.followsMouse)
        #expect(config.origins["layout.gaps"]?.line == 4)
    }

    @Test func scrollingOptions() {
        let config = evaluate("""
        [layout.scrolling]
        column-width = 0.8
        column-width-presets = [0.4, 0.6, 1]
        direction = "down"
        scroll-to = "fit"
        wrap = false
        """)
        #expect(config.diagnostics == [])
        let scrolling = config.settings.layout.scrolling
        #expect(scrolling.columnWidth == 0.8)
        #expect(scrolling.columnWidthPresets == [0.4, 0.6, 1])
        #expect(scrolling.direction == .down)
        #expect(scrolling.scrollTo == .fit)
        #expect(!scrolling.wraps)
    }

    @Test func mistakesAreReportedWithLinesAndSuggestions() {
        let config = evaluate("""
        [layout]
        gapz = 5
        style = "spiral"
        margins = "wide"

        [wobbly]
        amount = 1
        """)
        #expect(config.errors.map(\.location.line) == [1, 2, 3, 5])
        #expect(config.errors[0].message == "unknown option 'layout.gapz', did you mean 'layout.gaps'?")
        #expect(config.errors[3].message == "unknown table [wobbly]")
        #expect(config.errors[0].description == "moss.toml:2: error: unknown option 'layout.gapz', did you mean 'layout.gaps'?")
    }

    @Test func aListLeftOpenDoesNotSwallowTheNextTable() {
        let config = evaluate("""
        [layout]
        margins = [8, 8

        [borders]
        width = 3
        """)
        #expect(config.errors.map(\.location.line) == [1])
        #expect(config.errors.first?.message == "the list is not closed with ']'")
        #expect(config.settings.borders.width == 3)
    }

    @Test func valuesOfTheWrongTypeAreRejected() {
        let config = evaluate("[borders]\nwidth = \"thick\"\n\n[focus]\nfollows-mouse = 1\n")
        #expect(config.errors.count == 2)
    }

    @Test func shortcutsAndModes() throws {
        let config = evaluate("""
        [keyboard]
        main-key = "alt"

        [shortcuts]
        mod-return = "run open -na Terminal"
        mod-shift-c = { action = "close", description = "Close the window" }
        mod-l = { action = "resize by 20 0", repeat = true }
        cmd-alt-p = "palette"

        [modes.launch]
        t = { action = "run open -a Terminal", on-release = true }
        escape = "mode default"
        """)
        #expect(config.diagnostics == [])
        let terminal = try #require(config.bindings.first { $0.trigger == .key("return") })
        #expect(terminal.modifiers == .option)
        #expect(terminal.action == .run("open -na Terminal"))
        #expect(config.bindings.first { $0.trigger == .key("c") }?.summary == "Close the window")
        #expect(config.bindings.first { $0.trigger == .key("l") }?.options == .repeats)
        #expect(config.bindings.filter { $0.mode == "launch" }.count == 2)
        #expect(config.bindings.first { $0.mode == "launch" && $0.trigger == .key("t") }?.options == .onRelease)
    }

    @Test func includedFilesAreWatchedEvenWhenMissing() {
        let config = evaluate("include = [\"gone.toml\", \"themes/*.toml\"]\n")
        #expect(config.files.map(\.path) == ["/config/moss.toml", "/config/gone.toml"])
        #expect(config.filePatterns == ["/config/themes/*.toml"])
    }

    @Test func shortcutsToUndeclaredModesAreReported() {
        let config = evaluate("""
        [shortcuts]
        alt-r = "mode reszie"
        alt-l = "mode launch"

        [modes.resize]
        escape = "mode default"

        [modes.launch]
        """)
        #expect(config.modes == ["resize", "launch"])
        #expect(config.errors.map(\.location.line) == [1])
        #expect(config.errors.first?.message.contains("no mode 'reszie'") == true)
    }

    @Test func badShortcutsAreReported() {
        let config = evaluate("""
        [shortcuts]
        mod-q = "frobnicate"
        mod-left-drag = "move"
        squiggle-q = "close"
        mod-w = { action = "close", wobble = true }
        mod-e = 5
        """)
        #expect(config.errors.map(\.location.line) == [1, 2, 3, 4, 5])
        #expect(config.errors[0].message.contains("did you mean") == false)
        #expect(config.errors[1].message.contains("[mouse]"))
    }

    @Test func laterShortcutsReplaceEarlierOnes() {
        let config = evaluate("include = \"extra.toml\"\n\n[shortcuts]\nmod-q = \"close\"\n", files: ["/config/extra.toml": "[shortcuts]\nmod-q = \"quit\"\nmod-w = \"reload\"\n"])
        #expect(config.bindings.count == 2)
        #expect(config.bindings.first { $0.trigger == .key("q") }?.action == .close(nil))
    }

    @Test func mouse() {
        let config = evaluate("""
        [mouse]
        mod-left-drag = "move"
        mod-right-drag = "resize"
        mod-scroll-down = "workspace next"
        mod-middle-drag = "spin"
        """)
        #expect(config.bindings.count == 3)
        #expect(config.bindings.contains { $0.trigger == .drag(.right) && $0.command == .drag(.resize) })
        #expect(config.bindings.contains { $0.trigger == .scroll(.down) && $0.action == .workspace(.adjacent(1)) })
        #expect(config.errors.count == 1)
    }

    @Test func rules() throws {
        let config = evaluate("""
        [[rules]]
        if.app = "^com\\\\.apple\\\\.calculator$"
        float = true
        center = true

        [[rules]]
        if.title = "Picture in Picture"
        if.floating = true
        pin = true
        size = ["30%", "30%"]

        [[rules]]
        float = true

        [[rules]]
        if.app = "x"
        sparkle = true
        """)
        #expect(config.windowRules.count == 4)
        #expect(config.windowRules[0].effect == .float)
        #expect(config.windowRules[1].effect == .center)
        #expect(config.windowRules[3].effect == .size(.percent(30), .percent(30)))
        #expect(config.windowRules[3].conditions.count == 2)
        #expect(config.errors.map(\.location.line) == [11, 14])
    }

    @Test func workspacesAndScratchpads() throws {
        let config = evaluate("""
        [workspaces]
        back-and-forth = true

        [workspaces.3]
        name = "Mail"
        display = "built-in"
        persistent = true

        [workspaces.web]
        layout = "scrolling"

        [scratchpads.notes]
        when-empty = "open -a Notes"
        """)
        #expect(config.diagnostics == [])
        #expect(config.settings.workspaces.backAndForth)
        #expect(config.workspaceRules.count == 3)
        let mail = try #require(config.workspaceRules.first { $0.workspace == .numbered(3) })
        #expect(mail.name == "Mail" && mail.isPersistent && mail.display == .name("built-in"))
        #expect(config.workspaceRules.first { $0.workspace == .named("web") }?.layout == .scrolling)
        #expect(config.workspaceRules.first { $0.workspace == .scratchpad("notes") }?.whenEmpty == "open -a Notes")
    }

    @Test func displaysStartupAndEnvironment() {
        let config = evaluate("""
        [displays.all]
        reserve = [30, 0, 0, 0]

        [displays.built-in]
        reserve = 10

        [startup]
        run = ["echo one", "echo two"]

        [shutdown]
        run = "echo bye"

        [environment]
        EDITOR = "nvim"
        """)
        #expect(config.diagnostics == [])
        #expect(config.displayReservations == [
            MonitorReservation(monitor: nil, insets: Insets(top: 30, right: 0, bottom: 0, left: 0)),
            MonitorReservation(monitor: .name("built-in"), insets: Insets(all: 10)),
        ])
        #expect(config.startup == ["echo one", "echo two"])
        #expect(config.shutdown == ["echo bye"])
        #expect(config.environment.map(\.name) == ["EDITOR"])
    }

    @Test func includedFilesApplyBeforeTheFileIncludingThem() {
        let config = evaluate("include = \"parts/*.toml\"\n\n[layout]\ngaps = 9\n", files: [
            "/config/parts/a.toml": "[layout]\ngaps = 1\nmargins = 2\n",
            "/config/parts/b.toml": "borders.width = 3\n",
        ])
        #expect(config.diagnostics == [])
        #expect(config.settings.layout.gaps == Insets(all: 9))
        #expect(config.settings.layout.margins == Insets(all: 2))
        #expect(config.settings.borders.width == 3)
        #expect(config.files.count == 3)
    }

    @Test func includesThatLoopOrAreMissingAreReported() {
        let loop = evaluate("include = \"loop.toml\"\n", files: ["/config/loop.toml": "include = \"moss.toml\"\n"])
        #expect(loop.errors.contains { $0.message.contains("includes itself") })
        let missing = evaluate("include = [\"nowhere.toml\"]\n")
        #expect(missing.errors.count == 1)
    }

    @Test func shortcutsUseTheMainKeyFromAnyFile() {
        let config = evaluate("include = \"keys.toml\"\n\n[shortcuts]\nmod-q = \"close\"\n", files: ["/config/keys.toml": "keyboard.main-key = \"cmd\"\n"])
        #expect(config.bindings.first?.modifiers == .command)
    }
}

@Suite("Option registry")
struct RegistryTests {
    @Test func everyOptionRoundTripsItsDefault() throws {
        for option in OptionRegistry.all {
            var settings = Settings()
            #expect(throws: Never.self, "\(option.path)") { try option.apply(option.defaultValue, to: &settings) }
            #expect(settings == Settings(), "\(option.path) default does not round-trip")
            #expect(try option.text(from: option.tomlValue(fromText: option.defaultValue)) == option.defaultValue, "\(option.path)")
        }
    }

    @Test func pathsAreUniqueKebabCase() {
        let paths = OptionRegistry.all.map(\.path)
        #expect(Set(paths).count == paths.count)
        #expect(paths.allSatisfy { $0.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "." } })
    }

    @Test func validation() throws {
        let gaps = try #require(OptionRegistry.option("layout.gaps"))
        #expect(gaps.validate("5 10") == nil)
        #expect(gaps.validate("-1") != nil)
        let style = try #require(OptionRegistry.option("layout.style"))
        #expect(style.validate("stack") == nil)
        #expect(style.validate("spiral") != nil)
        #expect(OptionRegistry.suggestion(for: "layout.gap") == "layout.gaps")
        #expect(OptionRegistry.isCategory("layout.bsp"))
    }

    @Test func valuesAreWrittenAsTOML() throws {
        #expect(try #require(OptionRegistry.option("layout.gaps")).tomlValue(fromText: "4 8") == .array([.integer(4), .integer(8)]))
        #expect(try #require(OptionRegistry.option("layout.gaps")).tomlValue(fromText: "4") == .integer(4))
        #expect(try #require(OptionRegistry.option("layout.style")).tomlValue(fromText: "stack") == .string("stack"))
        #expect(try #require(OptionRegistry.option("dimming.enabled")).tomlValue(fromText: "true") == .boolean(true))
        #expect(try #require(OptionRegistry.option("dimming.amount")).tomlValue(fromText: "0.2") == .float(0.2))
    }
}
