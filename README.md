<p align="center"><img src="assets/icon/master.png" width="128" alt="docker-lease logo — a pixelated viking longship in Docker blue"></p>

# docker-lease

A lightweight macOS script that cleans up orphaned Docker Compose stacks left
behind by throwaway agent workspaces and CI runs—without touching anything
you're actually using.

No runtime dependencies beyond `docker` and `lsof`. It runs on the bash 3.2 that
ships with macOS, needs macOS 13 or newer, and is a single file you can read
before you trust it.

## The Problem

Agent harnesses and CI runners create a workspace, run `docker compose up -d`,
finish the task, and delete the workspace. Nothing runs `compose down`. The
scaffolded services usually carry `restart: always`, so the stack outlives the
workspace, the editor session, and often the reboot you hoped would clear it.

The result is a steady accumulation of containers nobody claims, ports held by
services nothing can reach, and disk and memory use ballooning the Docker VM
until the whole machine feels slow.

The hard part is that the obvious fixes are asymmetric. A stack from a finished
task keeps running for days, while any rule that looks safe on paper will
happily tear down the database your six-hour migration is still using four
minutes after you deleted the workspace that started it. One of those failure
modes wastes resources; the other destroys work.

`docker-lease` decides on ownership and observed activity, not on age.

## How it Decides What to Reap

Every pass asks Docker which compose projects exist and where their compose
file lives (`com.docker.compose.project.working_dir`). That label is the only
ownership signal that survives a Docker Desktop restart, and it is what the
classes below are built on. Containers started by hand with `docker run` carry
no compose project and are ignored entirely.

| Class | Condition | What happens |
|---|---|---|
| `USER` | working dir under `DOCKER_LEASE_USER_ROOT` (default `~/Projects`) | never touched |
| `AGENT` | working dir under `DOCKER_LEASE_AGENT_ROOT` (opt-in, empty by default) | idle decay applies |
| `STRAY` | working dir still exists, compose file is gone | stopped at once, containers deleted after `DOCKER_DELETE_HOURS` |
| `ORPHAN` | working dir no longer exists | deleted after two sightings at least `DOCKER_REAP_GRACE` apart |
| `UNKNOWN` | anything else, including missing labels | left alone, recorded as a note in the log |

`AGENT` is the only class that decays on a timer, and it stays empty until you
point it at your own workspace tree. With `DOCKER_LEASE_AGENT_ROOT` unset, no
stack is ever stopped or deleted on a timer — the safe default, not a bug.

Defaults on a decayed `AGENT` stack:

| Idle for | Action |
|---|---|
| 30 minutes (`DOCKER_STOP_MIN`) | containers stopped, `restart:` policy cleared — reversible with `docker start` |
| 24 hours (`DOCKER_DELETE_HOURS`) | containers deleted |

### The four veto signals

A stack is only stopped when **all four** signals agree it is idle. Any single
one of them vetoes the stop and re-stamps the activity file:

1. **Heartbeat lease.** A job that talks to a database but touches no files can
   call `docker-lease.sh heartbeat <project>`, which writes a timestamp for that
   project. The signal counts only while the lease is fresher than the stop
   window, so a stale lease cannot pin a stack open forever.
2. **File mtimes.** Any file under the compose working directory modified within
   the stop window — editors, test runners, `git` operations.
3. **Network byte deltas.** `NetIO` is sampled each pass and compared with the
   previous sample; growth above **1024 bytes** counts as activity. Bytes, not
   CPU: CPU jitters on an idle container and would make everything look busy.
   There is no comparison on the first pass, so the very first sample never
   vetoes.
4. **Live TCP sessions.** An `ESTABLISHED` local connection on one of the
   project's published ports.

## Safety Guarantees

- **Volumes are never deleted.** `docker-lease.sh volumes` counts dangling
  volumes and prints `docker system df`; nothing in the reap path removes one.
  Emptying a volume is unrecoverable, so it stays a human decision.
- **Restart policies are stripped before anything stops.** The `restart: always`
  that resurrects stacks at the next Docker Desktop launch is cleared first,
  so a stopped stack stays stopped.
- **Stop, then delete much later.** The default is a reversible `docker stop`
  after 30 idle minutes and deletion only after 24 hours. `ORPHAN` deletion is
  additionally gated behind a grace period of 600 seconds and must be seen in
  two separate passes, so a workspace being created right now is never torn out
  from under its agent.
- **Unclassifiable stacks are left alone.** No compose label, or a working
  directory outside both roots, produces a log note rather than an action.
- **Notifications fail softly.** Each stop and delete is announced through the
  optional notifier bundle; if that fails, an `osascript` fallback runs, and if
  both fail the error is logged and the reap continues. The message is passed
  as an argument, never interpolated into AppleScript source.

### How it compares

- `docker system prune` only sees what Docker already considers unused —
  stopped containers and dangling images. It cannot see a running-but-idle stack
  at all, and it will remove stopped containers you were deliberately keeping.
- Age-based reaper scripts measure one thing: how long a container has existed.
  That single timestamp cannot distinguish a stack abandoned last week from the
  one a six-hour migration is hammering right now.
- `docker-lease` combines an ownership class with the four-signal veto above, so
  the decision is "nobody owns this and nothing is using it" rather than "it is
  old".

## Install

```sh
git clone https://github.com/Bobnoddle/docker-lease.git
cd docker-lease
./install.sh
```

`install.sh` copies the script to `~/.local/bin`, builds the optional notifier,
appends a documented env block to your shell profile, and loads the launchd
agent. It stops nothing in Docker.

Requirements:

- macOS 13 or newer (Ventura+); tested on macOS 26
- `bash` 3.2 — the system bash is fine, nothing newer is required
- Docker Desktop, OrbStack or Colima with a reachable daemon, plus `lsof`
- **Optional:** the Swift toolchain (`xcode-select --install`), only to build
  the notification helper. Without it you get plain `osascript` notifications.

Run it read-only first:

```sh
~/.local/bin/docker-lease.sh status          # what it sees and how it classifies it
~/.local/bin/docker-lease.sh reap --dry-run  # exactly what the next pass would do
```

`~/.local/bin` is on `PATH` for most setups; add it yourself if it is not.
launchd re-runs the agent every 600 seconds (`StartInterval`), and `RunAtLoad`
is false, so a login does not immediately trigger a pass.

### Uninstall

```sh
./uninstall.sh            # keeps ~/.docker-leases history
./uninstall.sh --purge    # and the state directory
```

## Set up your agent root

`AGENT` classification is opt-in so the tool never claims a directory tree it
does not own. Point it at the parent of your throwaway workspaces:

```sh
# ~/.zshrc
export DOCKER_LEASE_AGENT_ROOT="$HOME/.local/share/opencode/worktree"   # example
```

That path is only an example — any harness or CI runner that creates per-task
worktrees works the same way, including plain git worktrees under `~/work/` or a
scratch directory. Whatever you choose, confirm it with
`docker-lease.sh status`: the stacks under that tree should show `AGENT`, and
everything else should stay `USER` or `UNKNOWN`.

## Configuration

Every knob is an env var, read at each launchd pass:

| Variable | Default | Purpose |
|---|---|---|
| `DOCKER_LEASE_ROOT` | `~/.docker-leases` | lease, pin, activity and log state |
| `DOCKER_LEASE_USER_ROOT` | `~/Projects` | never-reaped tree |
| `DOCKER_LEASE_AGENT_ROOT` | *(empty)* | idle-decayed tree |
| `DOCKER_STOP_MIN` | `30` | idle minutes before stop |
| `DOCKER_DELETE_HOURS` | `24` | hours before deletion |
| `DOCKER_REAP_GRACE` | `600` | seconds between the two `ORPHAN` sightings |
| `DOCKER` | `command -v docker` | docker binary |
| `DOCKER_LEASE_NOTIFY_BIN` | `~/.local/bin/docker-lease-notifier.app/...` | notifier executable |

Because launchd captures the environment at load time, re-run
`docker-lease.sh install` after exporting a new variable, or export it inside
the plist.

### Pinning

```sh
docker-lease.sh pin my-project     # never reaped, any class
docker-lease.sh unpin my-project
```

Pins are for the exception no signal captures — a stack you deliberately leave
running for a week. If you find yourself pinning routinely, the stop window is
shorter than the way you work.

### Heartbeats

```sh
docker-lease.sh heartbeat my-project   # call from a long-running job
```

A heartbeat writes a timestamp only; it does not touch Docker and it requires a
reachable daemon so a dead daemon never looks like activity.

## Notifications

Each stop and delete is reported once. Two paths:

1. **`docker-lease-notifier.app`** (built by `notifier/build.sh`) — a tiny
   `LSUIElement` bundle that posts through `UserNotifications`, so the banner
   carries the icon in `assets/icon/`.
2. **`osascript` fallback** — always built in, generic icon, used whenever the
   bundle is missing, unsigned, or exits non-zero.

The helper exits non-zero when the system has not authorized alerts, which is
why the fallback still works on a fresh machine. Grant it once, if you want the
icon:

```sh
~/.local/bin/docker-lease-notifier.app/Contents/MacOS/docker-lease-notify --request-authorization
```

Exit codes: `0` accepted, `1` authorization denied, `2` no message, `3` not
authorized or alert style off, `4` add failed, `5` request failed. **Exit 0 means
the system accepted the request, not that you saw it** — Focus modes accept and
present nothing. The script never treats a successful exit as proof of a visible
banner, and logs both paths failing.

Rebuild the bundle any time (icon included):

```sh
./notifier/build.sh                     # -> ~/.local/bin
./notifier/build.sh --out /tmp/preview  # somewhere harmless
```

`build.sh` compiles `arm64` and `x86_64` slices when the SDK supports both, lipos
them, ad-hoc signs, and prints the resulting architectures. If one slice cannot
be built it ships the other and says so.

## Repo layout

```
bin/docker-lease.sh     the reaper (single file, uses docker and lsof)
notifier/Notify.swift   notification helper source
notifier/build.sh       rebuilds the .app bundle from scratch (icons + signing)
assets/icon/master.png  icon artwork (see NOTICE.md before redistributing)
install.sh              script + notifier + env block + launchd agent
uninstall.sh            mirrors install.sh
```

## License

MIT — see [LICENSE](LICENSE). Icon provenance and its redistribution caveat are
in [NOTICE.md](NOTICE.md).
