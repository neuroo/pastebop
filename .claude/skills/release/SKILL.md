---
name: release
description: Cut a PasteBop release - bump the CalVer version, verify the build, tag, and let CI publish the .dmg. Use when asked to release, ship, cut a version, or publish a build.
---

# Releasing PasteBop

Versions are dates. `2026.09.11` today, `2026.09.11.2` for a second release the
same day. `CFBundleVersion` is the zero-padded `YYYYMMDDNN`, which always
increases; `Scripts/version.sh` derives both and rejects a date that does not
exist.

## Before tagging

Run all of these. The release workflow repeats the tests, but finding a failure
after the tag means deleting a tag.

```bash
swiftlint lint --strict                       # must be zero
swift test -c release                         # must be green
Scripts/build-app.sh && Scripts/package.sh    # must produce dist/*.dmg
```

Then verify what will actually be uploaded:

```bash
Scripts/verify-release.sh
```

It mounts the disk image and checks the app is there, signed, the right
version and architecture, with its assets compiled and the Applications alias
pointing where it should. The release workflow runs the same script before
publishing.

Then actually run the thing. A green suite has never caught a broken menu:

```bash
killall PasteBop 2>/dev/null; open dist/PasteBop.app
printf '“hello”—there…' | pbcopy && sleep 1 && pbpaste
```

Expect `"hello"--there...`. Open the menu and confirm the statistics submenu
and Help window render.

## Cutting it

```bash
Scripts/bump-version.sh                       # writes VERSION, prints the next steps
git commit -am "Release $(cat VERSION)"
git tag "v$(cat VERSION)"
git push --follow-tags
```

Pushing the tag runs `.github/workflows/release.yml`: it tests, builds, signs,
packages, and publishes. **It fails fast if `VERSION` and the tag disagree** --
that means `bump-version.sh` ran but the commit did not.

## Signing

Releases are ad-hoc signed unless the repository has `DEVELOPER_ID_P12`,
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and
`NOTARY_PASSWORD`. With them the workflow signs with the hardened runtime,
notarises, and staples, with no other change. Without them the release notes
tell users the `xattr -dr com.apple.quarantine` step.

Never weaken this by disabling Gatekeeper advice or shipping an unsigned build
that claims to be signed.

## If a release goes wrong

Do not force-push a tag. Bump to the next intra-day version
(`Scripts/bump-version.sh` again gives `.2`) and release forward. Delete the
bad GitHub release so nobody downloads it.

## Immutable releases

Planned, not yet enabled: turn it on once the pipeline has produced a few good
releases. The workflow is already shaped for it -- one `gh release create` with
both assets attached, no later `upload` or `edit`, and no tag rewriting -- and
`Scripts/verify-release.sh` exists because an immutable release cannot be
repaired, only superseded.

Once enabled, "delete the bad release" above stops being an option: releasing
forward is the only recovery.
