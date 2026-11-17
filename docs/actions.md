# Actions

An action is a verb and its arguments: `focus left`, `move-to-workspace 3`,
`run open -a Safari`. The same actions run from shortcuts, from the palette, from rules
(`when-empty`) and from the command line, as `moss focus left`.
`moss actions` lists them.

Most arguments name a window, a workspace or a display; they are described [below](#arguments).
Switches take `on`, `off` or `toggle`, and toggle when left out.

| Action | Arguments | What it does |
| --- | --- | --- |
| `run` | `[rules] COMMAND` | Run a shell command; rules in brackets apply to the window it opens |
| `close` | `[WINDOW]` | Close a window, the focused one by default |
| `quit-app` | `[WINDOW]` | Quit the application that owns a window |
| `signal` | `SIGNAL [WINDOW]` | Send a signal, such as TERM or USR1, to a window's process |
| `send-keys` | `KEYS [WINDOW]` | Press keys in a window's application, e.g. cmd-shift-t |
| `workspace` | `WORKSPACE` | Switch to a workspace |
| `move-to-workspace` | `WORKSPACE [WINDOW]` | Move a window to a workspace and follow it |
| `send-to-workspace` | `WORKSPACE [WINDOW]` | Move a window to a workspace and stay |
| `bring-workspace` | `WORKSPACE` | Show a workspace on the focused display |
| `rename-workspace` | `NUMBER [NAME]` | Name a numbered workspace, or clear its name |
| `scratchpad` | `[NAME]` | Show or hide a scratchpad |
| `float` | `[on\|off\|toggle] [WINDOW]` | Float a window above the tiles, or tile it |
| `fullscreen` | `[on\|off\|toggle]` | Cover the whole display with the focused window |
| `maximize` | `[on\|off\|toggle]` | Fill the layout area with the focused window |
| `keep-size` | `[on\|off\|toggle] [WINDOW]` | Keep a window's own size, centered in its tile |
| `pin` | `[on\|off\|toggle] [WINDOW]` | Keep a floating window on every workspace |
| `center` |  | Center the focused floating window |
| `tag` | `+NAME\|-NAME\|NAME [WINDOW]` | Add, remove or toggle a tag that rules can match |
| `bring-to-front` |  | Raise the focused floating window above the others |
| `focus` | `left\|right\|up\|down\|last` | Move focus, or return it to the previous window |
| `focus-window` | `WINDOW` | Focus a window |
| `cycle` | `[next\|previous] [tiled\|floating]` | Focus the next window on the workspace |
| `move` | `left\|right\|up\|down` | Move the focused window |
| `move-to-display` | `DISPLAY` | Move the focused window to another display |
| `swap` | `left\|right\|up\|down\|next\|previous` | Swap the focused window with another |
| `resize` | `by X Y \| to X Y` | Resize the focused window, in points or percent |
| `position` | `by X Y \| to X Y` | Move the focused floating window |
| `split-ratio` | `+0.1\|-0.1\|SHARE` | Change the share of the split around the focused window, such as 0.6 |
| `layout` | `bsp\|stack\|scrolling\|default\|toggle LAYOUT` | Change the focused workspace's layout; default goes back to the configured one |
| `focus-display` | `DISPLAY` | Focus another display |
| `move-workspace-to-display` | `DISPLAY [WORKSPACE]` | Move a workspace to another display |
| `swap-workspaces` | `DISPLAY DISPLAY` | Swap the workspaces shown on two displays |
| `tabs` |  | Put the focused window into a tab group, or dissolve its group |
| `tab` | `next\|previous\|NUMBER` | Show another tab of the group |
| `join-tabs` | `left\|right\|up\|down` | Move the focused window into the neighbouring tab group |
| `leave-tabs` |  | Take the focused window out of its tab group |
| `move-tab` | `next\|previous` | Move the focused tab within its group |
| `mode` | `NAME\|default` | Switch to a mode of its own shortcuts, or back |
| `emit` | `TEXT` | Send a custom event to scripts following the event stream |
| `palette` |  | Search windows, workspaces, actions and shortcuts |
| `overview` | `[next\|previous]` | See every workspace at once; again while open, highlight the next or previous one |
| `pause` | `[on\|off\|toggle]` | Stop arranging windows, or resume |
| `start-at-login` | `[on\|off\|toggle]` | Open Moss when you log in, or stop |
| `reload` |  | Read the configuration file again |
| `quit` |  | Quit Moss |

**BSP layout**

| Action | Arguments | What it does |
| --- | --- | --- |
| `flip-split` |  | Turn the split around the focused window |
| `swap-split` |  | Swap the two sides of the split around the focused window |
| `preselect` | `left\|right\|up\|down` | Choose where the next window opens |
| `promote` |  | Move the focused window to the top of the split tree |

**Stack layout**

| Action | Arguments | What it does |
| --- | --- | --- |
| `swap-main` |  | Swap the focused window with the main window |
| `focus-main` |  | Focus the main window, or the stack from it |
| `main-count` | `+1\|-1` | Add or remove a main window |
| `stack-side` | `left\|right\|top\|bottom\|center\|next\|previous` | Move the main area |
| `main-size` | `+0.05\|-0.05\|SIZE` | Change the share of the main area |
| `rotate` | `next\|previous` | Rotate windows through the main area |

**Scrolling layout**

| Action | Arguments | What it does |
| --- | --- | --- |
| `column` | `next\|previous` | Focus the next or previous column |
| `column-width` | `WIDTH\|+0.1\|-0.1\|next\|previous\|all WIDTH` | Change the focused column's width |
| `move-column` | `left\|right` | Move the focused column |
| `join-column` | `left\|right` | Move the focused window into the neighbouring column |
| `leave-column` |  | Give the focused window a column of its own |
| `fit` | `active\|visible\|all\|to-end\|to-start` | Resize columns to share the screen exactly |
| `scroll` | `POINTS` | Scroll the view |
| `reveal` |  | Scroll just enough to show the whole focused column |
| `scroll-to` | `center\|fit\|toggle` | Choose how focused columns are brought into view |
| `lock-view` | `[on\|off\|toggle]` | Keep the view still as focus moves |

Layout actions apply to the focused workspace's layout and are refused by the others.

## Arguments

**Windows.** Actions that take a window act on the focused one when it is left out. When several
windows match, the focused one is chosen if it is among them, and otherwise the one focused most
recently.

| Written | Window |
| --- | --- |
| `app:REGEX` | A window of an application, by bundle identifier or name |
| `title:REGEX` | A window whose title matches |
| `id:0x2a` | A window by its identifier, as `moss windows` shows it |
| `pid:1234` | A window of a process |
| `focused`, `floating`, `tiled` | The focused window, or a floating or tiled one |
| anything else | Same as `app:` |

**Workspaces.**

| Written | Workspace |
| --- | --- |
| `3` | A numbered workspace |
| `Mail`, `name:next` | A named workspace; `name:` allows names such as `next` |
| `next`, `previous` | The next or previous workspace on the display, among those that exist |
| `+1`, `-2` | Numbered workspaces counted from the current one |
| `last` | The workspace shown before the current one |
| `empty` | The first numbered workspace without windows |
| `scratchpad`, `scratchpad:NAME` | The default scratchpad, or a named one |

A window in macOS fullscreen, in a Space of its own, stays on its workspace. Switching to the
workspace shows that Space when the window was the last one used there, or the only one, and
activating the application, from a launcher for instance, shows the workspace. Switching to
another workspace brings the desktop back. While the Space is shown, `move-to-workspace` and
`send-to-workspace` move the window to another workspace, which then leads to it.

**Displays.**

| Written | Display |
| --- | --- |
| `left`, `right`, `up`, `down` | The neighbouring display in that direction |
| `next`, `previous`, `+1`, `-1` | Displays in order |
| `main` | The display with the menu bar |
| `current` | The focused display |
| `2` | A display by its `id`, as `moss displays` shows it |
| anything else | The first display whose name contains it, such as `built-in` |

**Commands with rules.** `run` can give the window its command opens some of the
[rules](configuration.md#rules), written in brackets before the command:

```toml
mod-return = "run [float, size=60% 70%, center] open -na Terminal"
mod-m = "run [workspace=5, silent] open -a Mail"
```

The rules apply to the next window of the application named with `open -a`, or to the next window
that opens at all when the command names none, for five seconds after the command runs.
