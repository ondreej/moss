# The moss command

`moss` runs actions and answers questions about a running Moss. It is inside the
application bundle at `Moss.app/Contents/Helpers/moss`; link it somewhere on your `PATH`:

```sh
ln -s /Applications/Moss.app/Contents/Helpers/moss /usr/local/bin/moss
```

## Actions

Anything that is not one of the requests below is an [action](actions.md):

```sh
moss workspace 2
moss move-to-workspace 3 app:Safari
moss run open -na Terminal
moss swap-main
moss reload
```

Mistakes are caught before anything is sent, with a suggestion when a name is close:

```
$ moss worksapce 2
moss: unknown action 'worksapce', did you mean 'workspace'?
```

## Requests

| Request | Answer |
| --- | --- |
| `windows` | Every window, with its workspace, frame and state |
| `workspaces` | Every workspace that exists |
| `displays` | Every display, with the workspace it shows |
| `focused` | The focused window |
| `shortcuts` | Every shortcut, written as in the configuration |
| `status` | The version, the Accessibility permission, whether tiling is paused, the mode and configuration problems |
| `get [OPTION]` | An option's value, default and whether the configuration sets it; every option without one |
| `set OPTION VALUE` | Change an option until the configuration is reloaded |
| `version` | The version |

```
$ moss windows
0x1a2b  1  tiled     Safari — Moss
0x1a31  1  tiled     Terminal — zsh
0x1a40  2  floating  Calculator — Calculator
$ moss set layout.gaps 12
ok
```

### JSON

`--json` answers in JSON, for scripts:

```sh
moss --json windows | jq -r '.[] | select(.workspace == "2") | .title'
moss --json get layout.style | jq -r .value
```

A window looks like this:

```json
{
  "app" : "Safari",
  "bundleID" : "com.apple.Safari",
  "display" : "Built-in Retina Display",
  "focusOrder" : 0,
  "frame" : {
    "height" : 1080,
    "width" : 834,
    "x" : 20,
    "y" : 57
  },
  "id" : "0x1a2b",
  "isFloating" : false,
  "isHidden" : false,
  "isPinned" : false,
  "keepsSize" : false,
  "pid" : 512,
  "tags" : [
    "work"
  ],
  "title" : "Moss",
  "workspace" : "1"
}
```

Frames are in points, with the origin at the top left of the main display. Workspaces are written
as in actions: `3`, `Mail` or `scratchpad:notes`. Fields without a value, such as `fullscreen` or
`tabs`, are left out. Fields are added over time; scripts should ignore the ones they do not know.

## Notices and the error bar

Scripts can put messages on screen:

```sh
moss notify Backup finished
moss notify --icon warning --seconds 8 Disk almost full
moss notify --color "#ff8800" Build failed
moss dismiss                      # remove every notice

moss error Backup failed          # a bar at the top of the screen, until the next reload
moss error --clear
```

Icons are `info`, `ok`, `warning` and `error`; each has a color of its own unless `--color` gives
one. The same bar lists problems in the configuration file while there are any, unless
`errors.show` is turned off.

## Without a running instance

```sh
moss check [FILE]           # report problems in a configuration file
moss options [FILTER]       # every option with its default
moss actions                # every action
moss init                   # write the default configuration if there is none
moss config-path
```

`options` and `actions` take `--markdown` to print tables like the ones in this documentation.

## Events

`moss events` prints events as they happen, one JSON object per line:

```json
{"display":"Built-in Retina Display","event":"workspace-shown","name":"Mail","workspace":"2"}
{"bundleID":"com.apple.Safari","event":"window-focused","title":"Moss","window":"0x1a2b"}
{"bundleID":"com.apple.Terminal","event":"window-opened","title":"zsh","window":"0x1a31","workspace":"2"}
```

| Event | Fields |
| --- | --- |
| `workspace-shown` | `workspace`, `name`, `display` |
| `display-focused` | `display`, `workspace` |
| `window-focused` | `window` (`null` when no window has focus), `bundleID`, `title` |
| `window-opened` | `window`, `workspace`, `bundleID`, `title` |
| `window-closed` | `window` |
| `window-moved` | `window`, `workspace` |
| `window-retitled` | `window`, `title` |
| `floating-changed` | `window`, `floating` |
| `pinned-changed` | `window`, `pinned` |
| `fullscreen-changed` | `window`, `fullscreen` |
| `workspace-created`, `workspace-removed` | `workspace` |
| `workspace-moved` | `workspace`, `display` |
| `workspace-renamed` | `workspace`, `name` |
| `scratchpad-shown` | `scratchpad` (`null` when hidden), `display` |
| `display-added`, `display-removed` | `display` |
| `tabs-created`, `tabs-dissolved` | `windows` |
| `window-joined-tabs`, `window-left-tabs` | `window` |
| `mode-changed` | `mode` |
| `tiling-paused` | `paused` |
| `config-reloaded` | |
| `custom` | `text`, sent with the `emit` action |

A status bar can follow them:

```sh
moss events | while IFS= read -r line; do
  workspace=$(printf '%s' "$line" | jq -r 'select(.event == "workspace-shown") | .workspace')
  [ -n "$workspace" ] && echo "now on workspace $workspace"
done
```

## Exit status

`0` on success, `1` when the request failed, `2` for a mistake in the command line and `3` when
Moss is not running.

## Sockets

The sockets live in `moss/` inside the per-user temporary directory, or in
`$MOSS_RUNTIME_DIR` when it is set. `control.sock` takes one request per connection, written
exactly as on the command line, and `events.sock` streams events. Any language can use them
directly:

```sh
echo "--json focused" | nc -U "$(getconf DARWIN_USER_TEMP_DIR)moss/control.sock"
```
