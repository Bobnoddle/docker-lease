# Contributing

Issues are welcome. Small, focused pull requests land faster than broad rewrites.

Keep `bash -n` green on every script you touch, and verify any behaviour claim in docs against the code, citing the `file:line` in your PR. The README is claim-checked against `bin/docker-lease.sh`, `install.sh` and `uninstall.sh`; PRs are held to the same bar.

Changes to the reap decision logic (ownership classes, thresholds, veto signals) need a proposal issue first, so the behaviour change is agreed before the diff exists.

Notifier changes must keep the unauthorized fail-safe: when alerts are not authorized the helper exits 3 and the `osascript` fallback runs. That path must not regress.
