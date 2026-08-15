# MixPill — downloads and updates

Per-application volume, EQ and output routing for macOS, live in the menu
bar. No audio driver, no system extension, no restart.

**[mixpill.app](https://mixpill.app)** · **[Download the latest
version](https://github.com/kuntayerkus/MixPill/releases/latest)**

## What this repository is

Only two things: `appcast.xml`, and the disk images attached to the
[releases](https://github.com/kuntayerkus/MixPill/releases). The source is
not here.

Every installed copy of MixPill reads
`https://raw.githubusercontent.com/kuntayerkus/MixPill/main/appcast.xml`
once a day to find out whether there is a newer version, and downloads the
disk image that file points at. That address is compiled into each build
and cannot be changed for a copy somebody has already installed — so this
repository has to stay public, keep its name, and keep its releases, for
as long as anyone is running MixPill.

Each entry in the feed carries an EdDSA signature over the exact bytes of
its disk image. The app verifies it and refuses anything that does not
match, so an update cannot be substituted even by someone who could change
what is served here.

## Where the source went

Into a private repository. It was readable here for the first two weeks
and is still reachable through the release tags, under the terms in
[LICENSE](LICENSE) — which is not an open source licence: reading and
building for yourself is allowed, redistributing is not.

## Reporting something

Bugs and questions: [issues](https://github.com/kuntayerkus/MixPill/issues),
or the address on [mixpill.app](https://mixpill.app).
