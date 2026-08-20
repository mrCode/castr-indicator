# Cast indicator

A bar widget for [Omarchy](https://omarchy.org) that casts your screen to an
Apple TV — mirror it, or extend onto it as a second desktop — and shows what is
casting.

![The cast panel](preview.png)

Click the icon for a panel listing the receivers on your network. Pick a mode
once, click a receiver, and it casts. Televisions sort above laptops, because a
colleague's MacBook answering AirPlay is noise. Right-click the icon to stop.

## Requires castr

The widget is a front end for [`castr`](https://github.com/mrCode/castr), which
does the actual work. Install it first:

```bash
yay -S castr doubletake-git
```

Without it the widget says so and tells you this command, rather than sitting
there looking idle.

Your firewall also has to let the receiver connect **back** to your machine:

```bash
sudo ufw allow 5353/udp
```

```bash
sudo ufw allow 60000:60010/tcp
```

```bash
sudo ufw allow 60000:60010/udp
```

## Install

```bash
omarchy plugin add https://github.com/mrCode/castr-indicator.git --enable --yes
```

## What it shows

- **Idle** — a dim icon; the panel lists what it can cast to
- **Connecting** — a screen-share prompt may be waiting for you; answer it
- **Streaming** — the receiver and mode, with a stop button
- **Failed** — what went wrong, in the receiver's own words where there are any

The icon stays visible whether or not you are casting. A control you cannot see
is a control you cannot find, and this one is how you stop.

## Mirror and extend

**Mirror** sends the screen you pick at the share prompt. Your panel keeps its
own resolution and refresh rate — castr does not touch it.

**Extend** gives you a second desktop. When the share prompt appears, pick the
output named `castr`, not your own screen; the portal remembers that choice.
If you pick wrong, `castr reset-share extend` asks again without making you
re-pair with the television.

## How it talks to castr

Three commands, all of them read-only until you click something:

| command | when |
|---|---|
| `castr bar` | polled every 2s; never starts a daemon |
| `castr list --json` | only while the panel is open |
| `castr status --json` | only while the panel is open |

Polling `castr bar` cannot start or keep alive a background daemon, so an idle
machine stays idle.

## Licence

MIT. Plugins run unsandboxed inside `omarchy-shell`; the source here is one QML
file, and it is worth the two minutes to read before you enable it.
