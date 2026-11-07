# Scrollar

A feed for researchers: scroll through new papers from the journals, topics,
people and keywords you follow, ranked by how close they are to your own work.

Status: prototype. An iPhone and iPad app (feed, saved papers, and a Tune screen
for everything that shapes the feed) on top of a tested core that also runs from
the command line.

```sh
Tests/run.sh                                    # pure functions, no network, no key
./run.sh 0000-0000-0000-0000                    # ORCID in, ranked feed out (needs a key)
./run.sh 0000-0000-0000-0000 --init-settings s.json   # write settings to edit
./run.sh --settings s.json                      # feed from a settings file

# The app. The simulator destination must be generic: named devices do not resolve here.
xcodebuild -project Scrollar.xcodeproj -scheme Scrollar \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/derived build
```

In a debug build the simulator can be started without typing a key:
`SIMCTL_CHILD_SCROLLAR_OPENALEX_KEY=… SIMCTL_CHILD_SCROLLAR_ORCID=… xcrun simctl launch <device> com.andremouraux.scrollar`.
The iOS Simulator has no Apple sentence-embedding model, so it ranks by word
counts only and the feed says so; check embeddings on a real device or with the
command line on a Mac.

## Refreshing

A refresh asks only for papers published since the last complete fetch, minus three
days of overlap, and merges them into the papers already held. OpenAlex's "added
since" filters are paid-plan only, so a paper indexed weeks after its publication date
can slip through; the whole window is therefore fetched again every three days, when the
settings change, and after a long absence. `./run.sh <orcid> --compare` runs a full
build and then an incremental one and checks they agree.

## Key

OpenAlex needs a free key (<https://openalex.org/settings/api>). Copy
`Secrets.example` to `Secrets.local` and put the key in it. `Secrets.local` is
gitignored; do not compile a key into the app. In the app, each user will paste
their own into Settings and it will live in the Keychain.

## Layout

- `Core/Model.swift`, `Seed.swift`, `Ranking.swift`: Foundation only, tested.
- `Core/Settings.swift`, `FeedBuilder.swift`: everything the user can tune, and what it does.
- `Core/OpenAlex.swift`, `PubMedClient.swift`, `Embedding.swift`: the network and
  Apple's NaturalLanguage; nothing else touches either.
- `Core/History.swift`: what was seen and read, and how a feed is sorted into new, earlier and read.
- `Core/Incremental.swift`: refreshing by asking only for what was published since the last fetch, and keeping the rest.
- `Core/Cover.swift`: the generated picture on each card (colour and symbol from the topic).
- `Core/Engine.swift`: settings in, ranked feed out. The app and the command line both call it.
- `App/`: SwiftUI. The OpenAlex key is in the Keychain, never in the settings file or the binary.
- `CLI/main.swift`: prototype driver.

Every seed (a topic, journal, author, keyword, or "cites my work") becomes one
OpenAlex query. Results are merged by DOI, ranked, and each card keeps the
reasons it appeared.
