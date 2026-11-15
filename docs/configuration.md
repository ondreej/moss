# Configuration

Moss reads `~/.config/moss/moss.toml` (or `$XDG_CONFIG_HOME/moss/moss.toml`),
a [TOML](https://toml.io) file. On first launch it writes one from its defaults. Changes apply as
soon as the file is saved, and the settings window edits the same file without disturbing your
comments or the order of your keys.

```toml
[keyboard]
main-key = "caps"          # the key most shortcuts start with, written `mod` below

[layout]
style = "bsp"              # bsp, stack or scrolling
gaps = 5
margins = [30, 20, 20, 20] # top, right, bottom, left

[borders]
active = "accent"

[shortcuts]
mod-return = "run open -na Terminal"
mod-h = "focus left"
mod-shift-h = "move left"
alt-1 = "workspace 1"
alt-shift-1 = "move-to-workspace 1"

[[rules]]
if.app = "com.apple.calculator"
float = true
```

`moss check` reports problems in the file without starting Moss. While Moss runs,
problems are listed in a bar at the top of the screen, each with its line, and the rest of the
file still applies.

## Shortcuts

Each entry in `[shortcuts]` is a combination of keys and the [action](actions.md) it runs:

```toml
[shortcuts]
mod-q = "close"
mod-shift-e = "run open ~"
cmd-alt-t = "run open -na Terminal"
mod-l = { action = "resize by 20 0", repeat = true }
mod-space = { action = "palette", description = "Find anything" }
```

Keys are written as modifiers followed by a key, joined with dashes:

- **Modifiers**: `mod` (the main key), `cmd`, `alt` (or `opt`), `ctrl`, `shift`, `caps`, `fn`,
  `hyper` (Shift, Control, Option and Command together) and `meh` (all of those but Command).
- **Keys**: letters and digits as they appear on your keyboard, `return`, `tab`, `space`,
  `escape`, `delete`, `backspace`, `left`, `right`, `up`, `down`, `home`, `end`, `page-up`,
  `page-down`, `f1` to `f20`, `keypad-0` to `keypad-9` and other `keypad-` keys, and punctuation by
  name: `minus`, `equal`, `plus`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backtick`,
  `backslash`, `left-bracket`, `right-bracket`, `section`. `keycode-N` names a key by its macOS
  virtual key code.

Letters follow the active keyboard layout, so `mod-z` is the key labeled Z on a German keyboard too.

**The main key.** `keyboard.main-key` chooses what `mod` stands for: `"caps"` (the default),
`"alt"`, `"cmd"`, `"ctrl"`, `"hyper"`, or a combination such as `"ctrl-alt"`.

**Caps Lock.** Held, Caps Lock is Hyper: Control, Option, Shift and Command together in every
application. Tapped alone, it still locks capitals. Moss's own shortcuts written with `caps`
(or `mod`, while Caps Lock is the main key) come first, and they can add the modifiers you really
hold: `caps-h` and `caps-shift-h` are different shortcuts, though to other applications both are
Hyper. A key that no `caps` shortcut takes reaches `hyper` shortcuts, then the application as
Hyper. No other keyboard utility is needed for this; Caps Lock is restored when Moss quits.

```toml
[shortcuts]
caps-h = "focus left"
caps-shift-h = "move left"
hyper-c = "run open -a Calendar"   # also works with a Hyper key from elsewhere
```

With `keyboard.caps-lock = "caps-lock"`, Caps Lock locks capitals as usual, unless a shortcut uses
it: then it is Moss's alone, and applications never see it.

A shortcut written as a table can also set:

| Key | Meaning |
| --- | --- |
| `action` | The action to run. Required. |
| `repeat` | Run again and again while the keys are held. |
| `on-release` | Run when the keys are released rather than pressed. |
| `pass-through` | Let the application receive the keys too. |
| `description` | How the settings window and the palette describe the shortcut. |

### Modes

A mode is a set of shortcuts of its own. `mode NAME` switches to it and `mode default` leaves it;
while a mode is active, only its shortcuts work.

```toml
[shortcuts]
mod-r = "mode resize"

[modes.resize]
right = { action = "resize by 20 0", repeat = true }
left = { action = "resize by -20 0", repeat = true }
escape = "mode default"
```

### The mouse

`[mouse]` drags windows and turns scrolling into actions:

```toml
[mouse]
mod-left-drag = "move"            # drag a window anywhere in it to move it
mod-right-drag = "resize"         # or to resize it from the nearest corner
mod-scroll-down = "workspace next"
mod-scroll-up = "workspace previous"
```

Buttons are `left`, `right` and `middle`; scrolling is `scroll-up`, `scroll-down`, `scroll-left`
and `scroll-right`. Dropping a tiled window in the middle of another tile swaps the two, keeping
every size; dropping it nearer an edge puts it beside that tile. A preview shows where it will land.

## Rules

Rules treat some windows differently. Each `[[rules]]` table has one or more conditions, written
`if.`, and the things to do with the windows that match all of them:

```toml
[[rules]]
if.app = "com.apple.calculator"
float = true
center = true

[[rules]]
if.app = "Slack"
workspace = 3
silent = true                     # open there without switching to it

[[rules]]
if.title = "Picture in Picture"
pin = true
size = ["25%", "25%"]
dim = false
```

Dialogs, panels, windows that cannot be resized and windows that cannot go fullscreen (such as
Finder's Get Info and System Settings) float without a rule. A rule with `float = false` tiles them.

**Conditions.** `if.app` and `if.title` are regular expressions matched anywhere in the text;
anchor them with `^…$` for an exact match. `if.app` matches the application's bundle identifier
(`com.apple.Safari`) or its name (`Safari`).

| Condition | Matches |
| --- | --- |
| `if.app` | The application's bundle identifier or name |
| `if.title` | The window's title |
| `if.workspace` | Windows on a workspace: a number, a name or `scratchpad:NAME` |
| `if.tag` | Windows with a tag, given by another rule or the `tag` action |
| `if.floating`, `if.fullscreen`, `if.pinned`, `if.focused`, `if.dialog`, `if.tabbed` | `true` or `false` |

**What rules do.** Rules about where a window opens apply once, when it opens. Rules about how it
looks follow it: when its title changes, it gains focus or a tag, they are applied again.

| Key | Value | Effect |
| --- | --- | --- |
| `float` | `true` or `false` | Float the window, or tile it even if it would float |
| `fullscreen`, `maximize` | `true` | Open fullscreen, or filling the layout area |
| `keep-size` | `true` | Keep the window's own size, centered in its tile |
| `pin` | `true` | Keep the floating window on every workspace |
| `center` | `true` | Center the floating window |
| `size` | `[WIDTH, HEIGHT]` | Size of the floating window, in points or `"50%"` |
| `position` | `[X, Y]` | Position of the floating window, in points or `"10%"` |
| `workspace` | workspace | Open on a workspace; with `silent = true`, without switching to it |
| `display` | display | Open on a display |
| `focus-on-open` | `false` | Open without taking focus |
| `focusable` | `false` | Never take focus |
| `keep-focus` | `true` | Keep focus until the window closes or another workspace is shown |
| `border` | `false` | Draw no border |
| `border-width` | number | Width of the border |
| `border-color` | colors | The focused color, optionally followed by the unfocused one |
| `corner-radius` | number | Corner radius of the border |
| `dim` | `false` | Never dim the window |
| `min-size`, `max-size` | `[WIDTH, HEIGHT]` | Limits for the floating window, in points |
| `tabs` | `"own"` or `"never"` | Open in a tab group of its own, or never join one |
| `tag` | text | Add a tag other rules can match with `if.tag` |

## Workspaces and scratchpads

Workspaces are created when they are needed and removed when they are empty and not shown.
Numbered workspaces sort first; any other name makes a named workspace. Give one settings of its
own with a `[workspaces.NAME]` table:

```toml
[workspaces.1]
name = "Web"
display = "built-in"
default = true                    # shown on that display at launch

[workspaces.5]
name = "Mail"
persistent = true
layout = "stack"
stack-side = "right"

[workspaces.notes]
when-empty = "[float] open -a Notes"
```

| Key | Effect |
| --- | --- |
| `name` | The name shown for a numbered workspace |
| `display` | The display the workspace belongs on |
| `default` | Show the workspace on its display at launch |
| `persistent` | Keep the workspace even while it is empty |
| `layout` | `bsp`, `stack` or `scrolling` |
| `gaps`, `margins`, `border-width` | Spacing of its own |
| `decorations` | `false` draws no borders or tab bars |
| `square-corners` | `true` gives borders square corners |
| `stack-side` | The side of the main area in the stack layout |
| `direction` | The direction of the strip in the scrolling layout |
| `when-empty` | A command to run when the workspace is opened with no windows; rules in brackets apply to the window it opens |

A **scratchpad** is a workspace that drops down over the one shown and hides again, such as a
terminal or notes kept a keystroke away. `scratchpad` shows the default one and
`scratchpad NAME` shows another; `send-to-workspace scratchpad:NAME` puts a window on it. Its
tables are `[scratchpads.NAME]`, with the same keys as workspaces.

## Displays

Displays are arranged in System Settings. The configuration can reserve space at their edges, for
a status bar, for example:

```toml
[displays.all]
reserve = [32, 0, 0, 0]           # top, right, bottom, left

[displays.built-in]
reserve = 0
```

A display is named by part of its name (`built-in`, `DELL`), by `main`, or by its `id` in
`moss displays`. When several tables match a display, the last one applies.

## Commands and the environment

```toml
[startup]
run = ["open -a Mail", "open -a Calendar"]

[shutdown]
run = "echo bye"

[environment]
EDITOR = "nvim"
```

`[startup]` commands run once when Moss starts, and `[shutdown]` commands when it quits.
Commands run through `/bin/sh` with the variables in `[environment]`.

## Including other files

```toml
include = ["keys.toml", "machines/*.toml"]
```

Paths are relative to the file that includes them and may use `*`. Included files apply before the
file that includes them, so it can override them; a shortcut defined twice takes the later one.

## Colors

Colors are written `"#rrggbb"`, `"#rrggbbaa"` or `"#rgb"`, `"accent"` for the accent color chosen
in System Settings, `"accent(0.5)"` for it at half opacity, or `"clear"`. Several colors followed
by an angle make a gradient: `"#ff9500 #ff2d55 45deg"`.

## Options

Every option below can be set in its table or with a dotted key (`layout.gaps = 8`), changed
while Moss runs with `moss set layout.gaps 8` (until the next reload), and found by
name in the settings window. `moss options` lists them with their defaults.

### `[keyboard]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `main-key` | modifier keys | `"caps"` | The key every shortcut starts with, written mod in shortcuts. |
| `caps-lock` | `"caps-lock"`, `"hyper"` | `"hyper"` | What Caps Lock does. As Hyper it is ⌃⌥⇧⌘ for every app while held, with Moss's caps shortcuts first, and locks capitals when tapped. |

### `[layout]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `style` | `"bsp"`, `"stack"`, `"scrolling"` | `"bsp"` | How tiled windows are arranged. |
| `gaps` | number (0–200), or up to four | `8` | Space between windows, in points. |
| `margins` | number (0–1000), or up to four | `8` | Space between windows and the edges of the screen. A list sets the top, right, bottom and left. |

### `[layout.bsp]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `new-window-side` | `"cursor"`, `"before"`, `"after"` | `"cursor"` | Which half of a split a new window takes. |
| `split-focused` | true or false | `true` | New windows split the focused window rather than the one under the cursor. |
| `keep-direction` | true or false | `false` | Splits keep their direction when their area changes shape. |
| `smart-split` | true or false | `false` | The side of a split follows the edge of the window the cursor is closest to. |
| `smart-resize` | true or false | `true` | Resizing moves the edges nearest the dragged corner. |
| `remember-preselection` | true or false | `false` | A preselected direction applies to every new window until it is changed. |
| `default-ratio` | number (0.05–0.95) | `0.5` | The share of a new split the first window gets: 0.5 is even, more favours the first window. |

### `[layout.stack]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `main-size` | number (0.05–0.95) | `0.55` | The share of the screen the main area takes. |
| `new-window` | `"main"`, `"stack"`, `"inherit"` | `"stack"` | Where new windows go. |
| `new-window-position` | `"end"`, `"start"`, `"before-focused"`, `"after-focused"` | `"end"` | Where new windows go in the order. |
| `side` | `"left"`, `"right"`, `"top"`, `"bottom"`, `"center"` | `"left"` | Where the main area is. |
| `center-min-stack` | whole number (0–100) | `2` | Stack windows needed before a centered main area takes effect. |
| `center-fallback` | `"left"`, `"right"`, `"top"`, `"bottom"`, `"center"` | `"left"` | Where the main area is while the stack is too small to center it. |
| `keep-main-position` | true or false | `false` | The main area keeps its place when the stack is empty. |

### `[layout.scrolling]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `column-width` | number (0.1–1) | `0.5` | The width of new columns, as a fraction of the screen. |
| `column-width-presets` | list of numbers | `[0.333, 0.5, 0.667, 1]` | The widths column-width next and previous step through. |
| `direction` | `"right"`, `"left"`, `"down"`, `"up"` | `"right"` | Where new columns are added and the view scrolls. |
| `scroll-to` | `"center"`, `"fit"` | `"center"` | How the view brings the focused column into sight. |
| `follow-focus` | true or false | `true` | The view scrolls to windows as they are focused. |
| `hover-min-visible` | number (0–1) | `0.4` | How much of a window must be in view for hovering it to focus it. |
| `fill-lone-column` | true or false | `true` | A workspace with a single column shows it across the whole screen. |
| `wrap` | true or false | `true` | Moving past either end with column or move-column wraps around to the other end. |

### `[borders]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `width` | number (0–100) | `1` | The width of the border around windows, in points. |
| `active` | color | `"accent"` | The border of the focused window. Several colors and an angle make a gradient. |
| `inactive` | color | `"clear"` | The border of other windows. |
| `follow-window-corners` | true or false | `true` | Borders follow each window's own rounded corners. |
| `corner-radius` | number (0–100) | `16` | The corner radius of borders around windows whose own corners cannot be read. |

### `[dimming]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | true or false | `false` | Dim windows other than the focused one. |
| `amount` | number (0–1) | `0.5` | How much windows are dimmed. |

### `[animation]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | true or false | `true` | Windows glide to their new places. |
| `duration` | number (0–5) | `0.18` | How long windows take to move, in seconds. |
| `curve` | `"smooth"`, `"ease-in-out"`, `"linear"` | `"smooth"` | How windows speed up and slow down as they move. |

### `[focus]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `follows-mouse` | true or false | `true` | Keyboard focus moves to the window under the cursor. |
| `move-cursor` | true or false | `true` | The cursor moves to windows focused with the keyboard. |
| `cross-displays` | true or false | `true` | Moving focus or a window past the last one goes on to the next display. |

### `[floating]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `snap` | true or false | `false` | Floating windows snap to each other and to the edges of the screen. |
| `snap-distance` | number (0–500) | `10` | How close a floating window must come to snap, in points. |

### `[fullscreen]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `new-window` | `"behind"`, `"take-over"`, `"exit"` | `"behind"` | What happens when a window opens on a workspace with a fullscreen window. |

### `[tabs]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `auto-join` | true or false | `true` | New windows join the focused window's tab group. |
| `bar` | true or false | `true` | A bar of tabs is shown above windows in a tab group. |
| `bar-height` | number (4–64) | `14` | The height of the bar of tabs, in points. |
| `titles` | true or false | `true` | Tabs show their window's title. |

### `[workspaces]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `back-and-forth` | true or false | `false` | Switching to the workspace already shown returns to the previous one. |
| `show-name` | true or false | `true` | The workspace's name appears briefly in the middle of the screen when switching to it. |

### `[scratchpads]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `scale` | number (0.1–1) | `1` | The size of tiled windows on a scratchpad, relative to their tile. |
| `dim-behind` | number (0–1) | `0.2` | How much the workspace behind an open scratchpad is dimmed. |
| `hide-on-workspace-switch` | true or false | `false` | Switching workspaces hides an open scratchpad. |

### `[errors]`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `show` | true or false | `true` | A bar at the top of the screen lists problems in the configuration file. |
