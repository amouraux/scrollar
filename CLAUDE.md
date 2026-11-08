# Working on Scrollar

A feed of research papers for scientists: iPhone, iPad and Mac (Mac Catalyst) from one
SwiftUI target, no third-party dependencies. `README.md` says what the app does and why;
this file is what to know before changing it.

## Commands

```sh
Tests/run.sh      # the core, no network, no key. Run first, and after every change to Core/.
```

Builds (all three must pass before anything is called done), and the iPhone install, are in
the README. The simulator destination must be `generic/platform=iOS Simulator`. Pass the signing team
on the command line (`DEVELOPMENT_TEAM=<id>`); none is committed. Do not push unless asked.

## The rule that keeps the tests possible

`Core/` imports Foundation only, except `Embedding.swift` (NaturalLanguage). `Tests/run.sh`
compiles the listed Core files with `Tests/main.swift`; a new Core file must be added to that
list. Anything worth testing (merging, routing, ranking, sync, parsing) is a pure function in
`Core/`, not in a view. Fixtures for network responses are written inline in the tests; never
test against a live service.

## Things that bite

- **A new field on `Paper`, `PubMedRecord`, or any stored `Codable` is optional or has a
  tolerant decoder.** Synthesised decoders demand every key, so a non-optional field throws away
  every cache written before it (`Paper.sources` did, and a test caught it). Memberwise
  initialisers take arguments in declaration order.
- **A new setting** needs a `CodingKeys` entry and a `get(...)` in `FeedSettings.init(from:)`
  (clamped if it has a range), and an entry in `SyncProjection` (`Core/Sync.swift`) or it will
  not sync. Decide whether it is a fetching setting or only a ranking one (`forFetching`,
  `forRanking`), or moving it will trigger a full rebuild or none at all.
- **A new `Seed` case** must be handled in `Seed.reason` and `filter`, `SourceRouting.targets` and
  `EuropePMCQuery.build`; the Swift switches are exhaustive on purpose.
- **A derived change must not look like an edit.** Sync stamps decisions with the time they
  were made; settings applied from the other device are recorded before they are applied, and
  defaults are stamped as the oldest thing. Do not bump a timestamp to make something propagate.
- **Raise `SyncDocument.currentFormat` for any change an older app would misread**, and never
  remove the guard: an app writes only a format it knows, and never overwrites a file that is not
  a sync file.
- **Never put the OpenAlex key anywhere but the Keychain** (and `Secrets.local`, gitignored, for
  the command line). It is not in the settings file, the sync file, a log line or an error message.
- **Do not trust a build.** `xcodebuild` can report success without relinking; compare the binary's
  timestamp with the edit. In zsh `log` is a builtin: use `/usr/bin/log`.
- **The Mac app's container cannot be read from a shell**, and its window cannot be captured
  without Screen Recording. The wide iPad simulator is the proxy for layout; use the unified log
  (subsystem `com.andremouraux.scrollar`) for what the app is doing.
- **No network on the main thread.** Refreshes and ranking run detached; the Apple model is used
  one paper at a time.

## House style

- Comments say why, not what.
- User-facing wording is plain, sentence case, and says what happened.
- A change to a post, a sheet or a menu lands on the phone and the Mac together; check the Mac
  build when touching gestures or menus (`#if targetEnvironment(macCatalyst)`).
- Dark mode is not an afterthought: colours on posts are checked for contrast (the banner's white
  text is why its colours are dark).
- Pure Foundation data is tested with named checks in `Tests/main.swift`; a name says the behaviour.

## Finishing a change

Run the tests, build the simulator and Mac targets, install on the iPhone if the change shows
there, update the README if behaviour changed, and commit with a message that explains the
reasoning. Record a decision not to build something in the README's "Not built, and why".
