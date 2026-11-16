# docker-lease

**Stop leaking Docker stacks from throwaway agent and CI workspaces — without
pruning anything that is actually in use.**

`docker-lease` is a small, dependency-free macOS agent that finds compose stacks
nobody owns any more, stops them after 30 minutes of idleness, and deletes their
containers after 24 hours. Volumes are never touched.

```
$ docker-lease.sh status
PROJECT              OWNER    RUN     PIN  IDLE     SINCE    STATE
----------------------------------------------------------------------------
acme-api             USER     yes     no   -        running  user (never reaped)
feat-4821-db         AGENT    yes     no   2h14m    running  up
feat-4799-web        ORPHAN   no      no   9h31m    stopped  down
```

## This is not another age-based prune

Age is the wrong signal. A container that has been up for six hours may be the
database your acceptance run is using right now; a container that started four
minutes ago may belong to a workspace deleted during the last rebase.

| | `docker-lease` | typical `docker-reaper` / `docker-sweep` scripts |
|---|---|---|
| Primary signal | ownership class + activity, sampled every 10 min | container age or `CreatedAt` |
| Protects a live stack | yes — four independent veto signals | no, unless you pin it manually every time |
| Knows what it does not own | yes — `UNKNOWN` is left alone | usually reaps everything matching a filter |
| Reversible by default | stop first, delete a day later | often `rm -f` on first pass |
| Volumes | reported, never deleted | varies |

If all you want is `docker system prune` on a timer, this is more machinery than
you need. It exists because a shared dev machine had 40 orphaned containers that
had ballooned the Docker VM to 8.6 GB on a 16 GB host, and every naive reaper
either killed work in progress or missed exactly the stacks that leaked.

## How it decides

Every pass enumerates stacks from compose labels
(`com.docker.compose.project` / `.project.working_dir`) — the only ownership
signal that survives a Docker Desktop restart. No labels, no opinion: stacks
started by hand with `docker run` are ignored.

Working directories fall into five classes:

| Class | Meaning | Action |
|---|---|---|
| `USER` | under `DOCKER_LEASE_USER_ROOT` (default `~/Projects`) | never auto-touched |
| `AGENT` | under `DOCKER_LEASE_AGENT_ROOT` (opt-in, empty by default) | idle decay applies |
| `STRAY` | directory exists, compose file is gone | stop now, delete after 24 h |
| `ORPHAN` | directory no longer exists | delete after a 10-minute grace |
| `UNKNOWN` | anything else | left alone, logged as a note |

`AGENT` is the only class that decays. It stays empty until you point
`DOCKER_LEASE_AGENT_ROOT` at the tree your agent harness creates workspaces in.
Nothing is assumed about which tool that is — see
[Set up your agent root](#set-up-your-agent-root).

### The four veto signals

A stack in `AGENT` is stopped only when **all four** say it is idle. Any one of
them vetoes the stop:

1. **Heartbeat lease** — `docker-lease.sh heartbeat <project>`, refreshed within
   the stop window. For jobs that talk to a database but touch no files.
2. **File mtimes** — any file under the working directory modified within the
   window. Catches editors, test runners, `git` operations.
3. **Network byte deltas** — `NetIO` growth over 1 kB between passes. Bytes, not
   CPU: CPU jitters on an idle container and would make everything look busy.
4. **Live TCP sessions** — an `ESTABLISHED` connection on a published port.

A working stack cannot talk itself into being reaped, which is the whole point.

### Decay

| Age since last activity | Action |
|---|---|
| ≥ 30 min (`DOCKER_STOP_MIN`) | stop containers, clear `restart:` policy — reversible with `docker start` |
| ≥ 10 min with zero activity (`DOCKER_FAST_STOP_MIN`) | same, tighter window for stacks that never show a signal |
| ≥ 24 h (`DOCKER_DELETE_HOURS`) | delete containers |

The restart policy is cleared **before** stopping. Otherwise the next Docker
Desktop launch resurrects everything and the leak survives the reboot that was
supposed to fix it.

**Volumes are never deleted.** They are reported by `docker-lease.sh volumes`,
because emptying one is unrecoverable and only a human can decide it is safe.

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
- Docker Desktop, OrbStack or Colima, with a reachable daemon
- **Optional:** the Swift toolchain (`xcode-select --install`) — only to build
  the notification helper. Without it you get plain `osascript` notifications.

Run it read-only first:

```sh
~/.local/bin/docker-lease.sh status        # what it sees and how it classifies it
~/.local/bin/docker-lease.sh reap --dry-run # exactly what the next pass would do
```

`~/.local/bin` is on `PATH` for most setups; add it yourself if it is not.

### Uninstall

```sh
./uninstall.sh            # keeps ~/.docker-leases history
./uninstall.sh --purge    # and the state directory
```

## Set up your agent root

`AGENT` classification is opt-in so that the tool never claims a directory tree
it does not own. Point it at the parent of your throwaway workspaces:

```sh
# ~/.zshrc
export DOCKER_LEASE_AGENT_ROOT="$HOME/.local/share/opencode/worktree"   # example
```

That path is only an example — any agent harness or CI runner that creates
per-task worktrees works the same way, including plain git worktrees under
`~/work/` or a scratch directory. Whatever you
choose, verify with `docker-lease.sh status`: the stacks under that tree should
show `AGENT`, and everything else should stay `USER` or `UNKNOWN`.

If `DOCKER_LEASE_AGENT_ROOT` is unset the class has no members and no stack is
ever stopped or deleted automatically. That is the safe default, not a bug.

## Configuration

Every knob is an env var, read at each launchd pass:

| Variable | Default | Purpose |
|---|---|---|
| `DOCKER_LEASE_ROOT` | `~/.docker-leases` | lease, pin, activity and log state |
| `DOCKER_LEASE_USER_ROOT` | `~/Projects` | never-reaped tree |
| `DOCKER_LEASE_AGENT_ROOT` | *(empty)* | idle-decayed tree |
| `DOCKER_STOP_MIN` | `30` | idle minutes before stop |
| `DOCKER_FAST_STOP_MIN` | `10` | tighter window when nothing ever moves |
| `DOCKER_DELETE_HOURS` | `24` | hours before deletion |
| `DOCKER_REAP_GRACE` | `600` | seconds a new `ORPHAN` must persist |
| `DOCKER` | `command -v docker` | docker binary |
| `DOCKER_LEASE_NOTIFY_BIN` | `~/.local/bin/docker-lease-notifier.app/...` | notifier executable |

launchd re-runs the agent every 600 seconds (`StartInterval`, `RunAtLoad` false).
Because launchd captures the environment at load time, re-run `docker-lease.sh
install` after exporting a new variable, or export it inside the plist.

### Pinning

```sh
docker-lease.sh pin my-project     # never reaped, any class
docker-lease.sh unpin my-project
```

Pins are for the exception that no signal captures — a stack you deliberately
leave running for a week. If you find yourself pinning routinely, the stop
window is too short for how you work.

### Heartbeats

```sh
docker-lease.sh heartbeat my-project   # call from a long-running job
```

## Notifications

Stopping and deleting a stack is reported once per action. Two paths:

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
authorized / alert style off, `4` add failed, `5` request failed. **Exit 0 means
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

## Safety notes

- **Volumes are never deleted**, only counted and reported.
- **Stops are reversible** with `docker start`; the restart policy has already
  been cleared, so nothing comes back on its own.
- **Deletion is delayed** by `DOCKER_DELETE_HOURS` behind the stop, and by
  `DOCKER_REAP_GRACE` behind first sighting of an orphan.
- **Unclassified stacks are untouched.** Wrong labels or no labels mean no
  action.
- The notification message is passed to `osascript` as **argv**, never
  interpolated into AppleScript source, so a project name cannot become code.
- The script is bash 3.2 compatible: no associative arrays, no `mapfile`.

## Repo layout

```
bin/docker-lease.sh    the reaper (single file, no dependencies beyond docker)
notifier/Notify.swift  notification helper source
notifier/build.sh      rebuilds the .app bundle from scratch (icons + signing)
assets/icon/master.png icon artwork (see NOTICE.md before redistributing)
install.sh             script + notifier + env block + launchd agent
uninstall.sh           mirrors install.sh
```

## License

MIT — see [LICENSE](LICENSE). Icon provenance and its redistribution caveat are
in [NOTICE.md](NOTICE.md).
