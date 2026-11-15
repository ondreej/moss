/// The configuration written on first launch.
public enum DefaultConfiguration {
    public static let text = #"""
    # Moss
    #
    # Changes apply as soon as the file is saved. The settings window edits it too,
    # keeping your comments. The documentation describes every option and action.

    [keyboard]
    # The key most shortcuts start with, written `mod` below:
    # caps, alt, cmd, ctrl or hyper.
    main-key = "caps"
    # Hold Caps Lock for shortcuts and tap it to lock capitals. While it is held,
    # other apps see Hyper (ctrl-alt-shift-cmd), and Moss's caps shortcuts can
    # add Shift or Option.
    caps-lock = "hyper"

    [layout]
    # bsp, stack or scrolling
    style = "bsp"
    gaps = 8
    margins = 8

    [borders]
    width = 1
    active = "accent"
    inactive = "clear"

    [animation]
    enabled = true

    [focus]
    follows-mouse = true

    [shortcuts]
    # One rule throughout: a key goes somewhere, and with Shift it takes the
    # window along.

    # Workspaces: Option and a number goes there,
    # Option-Shift and a number takes the window
    alt-1 = "workspace 1"
    alt-2 = "workspace 2"
    alt-3 = "workspace 3"
    alt-4 = "workspace 4"
    alt-5 = "workspace 5"
    alt-6 = "workspace 6"
    alt-7 = "workspace 7"
    alt-8 = "workspace 8"
    alt-9 = "workspace 9"
    alt-0 = "workspace 10"
    alt-shift-1 = "move-to-workspace 1"
    alt-shift-2 = "move-to-workspace 2"
    alt-shift-3 = "move-to-workspace 3"
    alt-shift-4 = "move-to-workspace 4"
    alt-shift-5 = "move-to-workspace 5"
    alt-shift-6 = "move-to-workspace 6"
    alt-shift-7 = "move-to-workspace 7"
    alt-shift-8 = "move-to-workspace 8"
    alt-shift-9 = "move-to-workspace 9"
    alt-shift-0 = "move-to-workspace 10"
    mod-tab = "workspace last"

    # Windows: Caps Lock and H/J/K/L (or the arrows) moves focus,
    # with Shift moves the window, with Option resizes it
    mod-h = "focus left"
    mod-j = "focus down"
    mod-k = "focus up"
    mod-l = "focus right"
    mod-left = "focus left"
    mod-down = "focus down"
    mod-up = "focus up"
    mod-right = "focus right"
    mod-shift-h = "move left"
    mod-shift-j = "move down"
    mod-shift-k = "move up"
    mod-shift-l = "move right"
    mod-shift-left = "move left"
    mod-shift-down = "move down"
    mod-shift-up = "move up"
    mod-shift-right = "move right"
    mod-alt-h = { action = "resize by -40 0", repeat = true }
    mod-alt-j = { action = "resize by 0 40", repeat = true }
    mod-alt-k = { action = "resize by 0 -40", repeat = true }
    mod-alt-l = { action = "resize by 40 0", repeat = true }
    mod-alt-left = { action = "resize by -40 0", repeat = true }
    mod-alt-down = { action = "resize by 0 40", repeat = true }
    mod-alt-up = { action = "resize by 0 -40", repeat = true }
    mod-alt-right = { action = "resize by 40 0", repeat = true }

    # The window itself
    mod-w = "close"
    mod-f = "fullscreen"
    mod-t = "float"
    mod-g = "tabs"
    mod-slash = "flip-split"

    # A scratchpad drops down over the workspace and hides again;
    # Shift sends the window there
    mod-s = "scratchpad"
    mod-shift-s = "send-to-workspace scratchpad"

    mod-space = "palette"
    # Every workspace at a glance. Press it again with the keys held to step
    # through them, with Shift to step back, and let go to go there.
    mod-o = "overview"
    mod-shift-o = "overview previous"

    # Moss opens no applications of its own.
    # `run` starts any command, for example:
    # mod-return = "run open -na Terminal"

    # Modes give keys a meaning of their own until you leave them, for example:
    # mod-r = "mode resize"
    #
    # [modes.resize]
    # left = { action = "resize by -20 0", repeat = true }
    # right = { action = "resize by 20 0", repeat = true }
    # escape = "mode default"

    [mouse]
    mod-left-drag = "move"
    mod-right-drag = "resize"
    mod-scroll-down = "workspace next"
    mod-scroll-up = "workspace previous"

    # Rules treat some windows differently. Dialogs, panels and windows that cannot
    # be resized float without one.
    #
    # [[rules]]
    # if.app = "com.apple.calculator"
    # float = true
    #
    # [[rules]]
    # if.app = "com.tinyspeck.slackmacgap"
    # workspace = 2
    # silent = true

    # Workspaces can have names, displays and settings of their own.
    #
    # [workspaces.5]
    # name = "Mail"
    # display = "built-in"
    """#
}
