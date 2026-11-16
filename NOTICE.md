# NOTICE

## Icon artwork

`assets/icon/master.png` is original artwork made for this project and is the
only icon asset the repository ships. No third-party icon set or stock image is
included.

The artwork is not covered by the MIT license that applies to the source code
(see [LICENSE](LICENSE)). It identifies this project, so it travels with it; if
you fork and rebrand, replace `assets/icon/master.png` with your own image. Any
PNG works, square or not, and `notifier/build.sh` centres it on a transparent
canvas.

## Third-party names

Docker, Docker Desktop, OrbStack, Colima and macOS are trademarks of their
respective owners. They are named only to describe compatibility. docker-lease is
not affiliated with, endorsed by, or sponsored by any of them.

## Notification title

The notification helper posts under the title `docker reaper` and the bundle is
named accordingly, so the permission appears in System Settings under that name.
This is the action the tool performs, kept stable so existing permission grants
keep working across versions.
