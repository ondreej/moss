# End-to-end tests

These scenarios run against a live Moss instance on a real macOS session. They open
windows with a small test app (`WindowFactory`), drive Moss through its control socket,
and check both Moss's model and the geometry the window server actually shows.

They move, resize and close windows, so run them on a machine or virtual machine dedicated
to testing, never on a session you are working in.

```sh
Scripts/build-e2e.sh                     # builds build/e2e/{moss-e2e,WindowFactory.app}
build/e2e/moss-e2e build/e2e/WindowFactory.app            # all scenarios
build/e2e/moss-e2e build/e2e/WindowFactory.app "stack"    # scenarios matching a filter
```

Moss must be running with the Accessibility permission. Windows that do not belong to the
suite are moved to workspace 99 before the scenarios start.
