# Docker — Omarchy bar widget

Bring Docker Compose stacks up, down, build and rebuild them from the Omarchy
status bar.

![bar icon](https://img.shields.io/badge/omarchy-plugin-blue)

## What it shows

One row per Compose stack, merged from two sources that each know half the
answer: `docker compose ls` knows the live state, but only of stacks the daemon
has already seen; a scan of your project folders knows every repository that has
a compose file, including the ones you have never started. Either one alone
leaves out rows you want.

The bar icon carries the count of running stacks, colored by whether all, some,
or none of them are up.

## Actions

| Key | Action  | Command                                        |
|-----|---------|------------------------------------------------|
| `u` | Up      | `docker compose up -d`                          |
| `d` | Down    | `docker compose down`                           |
| `r` | Restart | `docker compose restart`                        |
| `b` | Build   | `docker compose build`                          |
| `f` | Rebuild | `docker compose up -d --build --force-recreate` |
| `o` | Logs    | floating terminal following the stack's logs    |

`j`/`k` move between stacks, `Enter` toggles the selected one up or down, and
`Space` refreshes. Actions run one process per stack, so a long rebuild of one
never blocks the rest — and because the result outlives the panel, it arrives as
a notification when it lands.

## Install

```bash
omarchy plugin add https://github.com/piazzaAI/omarchy-docker.git --enable
```

## Settings

Configured through the widget's settings in the Omarchy shell:

| Setting | Default | Meaning |
|---|---|---|
| `roots` | `~/dev` | Comma-separated folders scanned one level deep for compose files |
| `refreshIntervalSec` | `10` | Poll interval while the panel is open |
| `hideIdle` | `false` | Hide stacks that have never been started |
| `showCount` | `true` | Show the running stack count on the bar |

## Helper scripts

Both are plain CLIs that emit JSON, so a Hyprland keybinding can do exactly what
the panel does:

```bash
omarchy-docker-stacks --roots ~/dev
omarchy-docker-action rebuild hades --notify
```

## Requirements

`docker`, `docker compose` and `jq`, with the Docker socket reachable by your
user (`omarchy setup security sudoless-docker` if it is not).

## License

MIT
