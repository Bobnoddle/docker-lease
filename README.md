<p align="center"><img src="assets/icon/master.png" width="200" alt="a pixelated viking longship in Docker blue"></p>

<h1 align="center">docker-lease</h1>

<p align="center">A lightweight macOS script that cleans up orphaned Docker Compose stacks left behind by throwaway agent workspaces and CI runs, without touching anything you're actually using.</p>

<p align="center"><sub>No runtime dependencies beyond <code>docker</code> and <code>lsof</code>. bash 3.2, macOS 13 or newer, a single file you can read before you trust it.</sub></p>

---

## Quick start

1. Clone it.
   ```sh
   git clone https://github.com/Bobnoddle/docker-lease && cd docker-lease
   ```
2. Read `bin/docker-lease.sh`. It is one file, and every decision it makes is in plain sight.
3. Install it.
   ```sh
   ./install.sh
   ```
   It copies the script to `~/.local/bin`, builds the optional notifier, appends an env block to your shell profile, and loads a LaunchAgent named `io.github.bobnoddle.docker-lease.reaper`. No sudo, and nothing in Docker is stopped, started or removed.

Check it worked:

```sh
~/.local/bin/docker-lease.sh status
```

```
PROJECT              OWNER    RUN     PIN  IDLE     SINCE    STATE
----------------------------------------------------------------------------
quark                USER     yes     no   -        -        user (never reaped)
```

The example uses the full path; `~/.local/bin` is on `PATH` in most shells, so
`docker-lease.sh` works too.

Undo: `./uninstall.sh` removes the agent, the script, the notifier and the env block. Add `--purge` to also delete `~/.docker-leases`.

## What it does

- Enumerates compose projects from the `com.docker.compose.project` and `working_dir` labels, so containers started by hand with `docker run` are ignored.
- `AGENT` stacks idle for 30 minutes are stopped, with the restart policy stripped first so they stay stopped; `docker start` brings them back. After 24 hours their containers are deleted.
- Your `~/Projects` tree, pinned projects and every volume are never deleted.
- A launchd agent runs a pass every 10 minutes. There is no daemon.

Four independent activity signals must all agree that a stack is idle before it is touched. Details in [How it decides](#how-it-decides-what-to-reap).

## Requirements

- macOS 13 or newer (Ventura+); tested on macOS 26.
- The bash 3.2 that ships with macOS, nothing newer.
- The Docker CLI with a reachable daemon, plus `lsof`; Docker Desktop, OrbStack and Colima all work. The notifier is optional: without the Swift toolchain you get `osascript` notifications instead.

## The Problem

Agent harnesses and CI runners create a workspace, run `docker compose up -d`,
finish the task and delete the workspace. Nothing runs `compose down`, and the
scaffolded services usually carry `restart: always`, so the stack outlives the
workspace, the editor session and often the reboot you hoped would clear it.

The obvious fixes are asymmetric. A stack from a finished task keeps running for
days, while any rule that looks safe on paper will tear down the database your
six-hour migration is still using four minutes after you deleted the workspace
that started it. One of those failure modes wastes resources, the other destroys
work. `docker-lease` decides on ownership and observed activity, not age.

## How it Decides What to Reap

Every pass asks Docker which compose projects exist and where their compose
file lives (`com.docker.compose.project.working_dir`). That label is the only
ownership signal that survives a Docker Desktop restart, and it is what the
classes below are built on.

| Class | Condition | What happens |
|---|---|---|
| `USER` | working dir under `DOCKER_LEASE_USER_ROOT` (default `~/Projects`) | never touched |
| `AGENT` | working dir under `DOCKER_LEASE_AGENT_ROOT` (opt-in, empty by default) | idle decay applies |
| `STRAY` | working dir still exists, compose file is gone | stopped at once, containers deleted after `DOCKER_DELETE_HOURS` |
| `ORPHAN` | working dir no longer exists | deleted after two sightings at least `DOCKER_REAP_GRACE` apart |
| `UNKNOWN` | anything else, including missing labels | left alone, recorded as a note in the log |

`AGENT` is the only class that decays on a timer, and it stays empty until you
point it at your own workspace tree. With `DOCKER_LEASE_AGENT_ROOT` unset, no
stack is ever stopped or deleted on a timer. That is the safe default, not a bug.

```sh
# ~/.zshrc: any harness or CI runner that makes per-task worktrees works here.
# This path is only an example.
export DOCKER_LEASE_AGENT_ROOT="$HOME/.local/share/opencode/worktree"
```

Confirm with `docker-lease.sh status`: the stacks under that tree show `AGENT`,
and everything else stays `USER` or `UNKNOWN`, including plain git worktrees
under `~/work/`.

Defaults on a decayed `AGENT` stack:

| Idle for | Action |
|---|---|
| 30 minutes (`DOCKER_STOP_MIN`) | containers stopped, `restart:` policy cleared, reversible with `docker start` |
| 24 hours (`DOCKER_DELETE_HOURS`) | containers deleted |

### The four veto signals

A stack is only stopped when **all four** signals agree it is idle. Any single
one of them vetoes the stop and re-stamps the activity file:

1. **Heartbeat lease.** A job that talks to a database but touches no files can
   call `docker-lease.sh heartbeat <project>`, which writes a timestamp for that
   project. The signal counts only while the lease is fresher than the stop
   window, so a stale lease cannot pin a stack open forever.
2. **File mtimes.** Any file under the compose working directory modified within
   the stop window: editors, test runners, `git` operations.
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
  that resurrects stacks at the next Docker Desktop launch is cleared first.
- **Orphans get a grace period.** An `ORPHAN` must be seen in two separate
  passes at least 600 seconds apart, so a workspace being created right now is
  never torn out from under its agent.
- **Unclassifiable stacks are left alone.** No compose label, or a working
  directory outside both roots, produces a log note rather than an action.
- **Notifications fail softly.** Each stop and delete is announced through the
  optional notifier bundle; if that fails, an `osascript` fallback runs, and if
  both fail the error is logged and the reap continues. The message is passed
  as an argument, never interpolated into AppleScript source.

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

## Pinning

```sh
~/.local/bin/docker-lease.sh pin my-project     # never reaped, any class
~/.local/bin/docker-lease.sh unpin my-project
```

Pins are for the exception no signal captures: a stack you deliberately leave
running for a week. If you find yourself pinning routinely, the stop window is
shorter than the way you work.

## Heartbeats

```sh
~/.local/bin/docker-lease.sh heartbeat my-project   # call from a long-running job
```

A heartbeat writes a timestamp only; it does not touch Docker and it requires a
reachable daemon so a dead daemon never looks like activity.

## Notifications

Each stop and delete is reported once. Two paths:

1. **`docker-lease-notifier.app`** (built by `notifier/build.sh`): a tiny
   `LSUIElement` bundle that posts through `UserNotifications`, so the banner
   carries the icon in `assets/icon/`.
2. **`osascript` fallback**: always built in, generic icon, used whenever the
   bundle is missing, unsigned, or exits non-zero.

The helper exits non-zero when the system has not authorized alerts, which is
why the fallback still works on a fresh machine. Grant it once, if you want the
icon:

```sh
~/.local/bin/docker-lease-notifier.app/Contents/MacOS/docker-lease-notify --request-authorization
```

Exit codes: `0` accepted, `1` authorization denied, `2` no message, `3` not
authorized or alert style off, `4` add failed, `5` request failed. **Exit 0 means
the system accepted the request, not that you saw it.** Focus modes accept and
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

## How it compares

- `docker system prune` only sees what Docker already considers unused:
  stopped containers and dangling images. It cannot see a running-but-idle stack
  at all, and it will remove stopped containers you were deliberately keeping.
- Age-based reaper scripts measure one thing: how long a container has existed.
  That single timestamp cannot distinguish a stack abandoned last week from the
  one a six-hour migration is hammering right now.
- `docker-lease` combines an ownership class with the four-signal veto above, so
  the decision is "nobody owns this and nothing is using it" rather than "it is
  old".

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

MIT. See [LICENSE](LICENSE). Icon provenance and its redistribution caveat are
in [NOTICE.md](NOTICE.md).
