# Privacy Policy

**PasteBop does not collect any data.**

Last updated: 12 September 2026

## What PasteBop reads

PasteBop watches the macOS clipboard so it can rewrite typographic and
invisible characters into their plain-keyboard equivalents. To do that it
reads the text you copy, transforms it in memory, and writes the result back
to the clipboard.

That text is never stored, never written to disk, and never transmitted. It
exists only for as long as the rewrite takes.

## What PasteBop stores on your Mac

Two things, both local to your Mac and both inside the app's own sandbox
container:

- **Counts.** How many times each character was replaced, how many copies
  there have been, and the date counting started. These are integers. The text
  they came from is not kept. You can clear them at any time with
  **Statistics ▸ Reset Statistics**.
- **Your rules.** Any change you make to which characters are rewritten, and
  what they become, in a plain text file you can read and edit yourself.

The "reads machine-written" line in the menu is computed from those integers
alone — how many distinct families of typographic marker appeared and how
densely. It does not examine the text, and it is a heuristic that is wrong
about people who type em dashes by hand.

## What PasteBop sends

Nothing to us, and nothing to anyone else.

One thing does leave your Mac. If you are signed in to iCloud, the changes you
have made to the rules — which characters are rewritten and what they become,
and nothing else — sync between your own Macs through iCloud key-value
storage, the same mechanism system settings use. They go to your iCloud
account. There is no PasteBop server and no PasteBop account, so there is
nowhere for them to reach us and no way for us to read them. **The text you
copy is never part of this**, and neither are the counts. Builds you compile
yourself have this switched off entirely.

Beyond that, PasteBop runs under the macOS App Sandbox and requests no network
entitlement of its own. The application binary links no networking framework.
There is no account, no sign-in, no analytics, no crash reporting, no
advertising, and no third-party SDK of any kind. The app has no third-party
dependencies.

## Data collected by the developer

None. No data is collected, so none is linked to you, used to track you, or
shared with anyone.

## Children

PasteBop is suitable for all ages and collects no data from anyone, including
children.

## Changes to this policy

If a future version of PasteBop ever handles data differently, this policy
will be updated before that version ships, and the change will be visible in
this file's history.

## Contact

Questions about this policy: open an issue at
<https://github.com/neuroo/pastebop/issues>.
