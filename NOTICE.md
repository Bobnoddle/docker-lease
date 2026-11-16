# NOTICE

## Icon artwork — redistribution caveat

`assets/icon/master.png` (a stylised Viking-ship logo) was generated with
**Google Gemini**, an AI image generator, and is included here for use with the
docker-lease notifier.

It is **not** covered by the MIT license that applies to the source code. The
copyright status of AI-generated images is unsettled and depends on the terms of
the generator that produced it:

- Google's terms for Gemini and related generative media have changed repeatedly
  and restrict some commercial and redistribution uses.
- Outputs may also reproduce elements of training data, which can carry their
  own rights.
- This notice is not legal advice.

**Before publishing, redistributing, or using this image commercially, verify
Google's current Terms of Service / Generative AI Prohibited Use Policy yourself.**

If they do not permit your intended use, replace `assets/icon/master.png` with
artwork you own or that is licensed for your use (any square or non-square PNG
works; `notifier/build.sh` centres it on a transparent canvas), and keep the rest
of the project unchanged.

## Third-party names

Docker, Docker Desktop, OrbStack, Colima and macOS are trademarks of their
respective owners. They are named only to describe compatibility. docker-lease is
not affiliated with, endorsed by, or sponsored by any of them.

## Notification title

The notification helper posts under the title `docker reaper` and the bundle is
named accordingly, so the permission appears in System Settings under that name.
This is the action the tool performs, kept stable so existing permission grants
keep working across versions.
