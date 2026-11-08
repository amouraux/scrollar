# Scrollar

A feed for researchers: scroll through new papers from the journals, topics,
people and keywords you follow, ranked by how close they are to your own work.

Status: working prototype, used daily on an iPhone. One SwiftUI app for iPhone, iPad and
Mac (Mac Catalyst), on top of a tested core that also runs from the command line. Screens:
Feed, Saved (and Read), and Tune, which holds everything that shapes the feed.

## Commands

```sh
Tests/run.sh                                    # the pure core: no network, no key, a second
./run.sh 0000-0000-0000-0000                    # ORCID in, ranked feed out
./run.sh 0000-0000-0000-0000 --init-settings s.json   # write the settings to edit
./run.sh --settings s.json                      # feed from a settings file
# more flags: --days N  --top N  --no-embeddings  --compare  --no-openalex  --no-europepmc
```

Build, all three; the simulator destination must be generic (named devices do not resolve):

```sh
xcodebuild -project Scrollar.xcodeproj -scheme Scrollar \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/derived build
xcodebuild -project Scrollar.xcodeproj -scheme Scrollar \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/derived-mac \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team id> build
xcodebuild -project Scrollar.xcodeproj -scheme Scrollar -destination 'id=<iPhone UDID>' \
  -derivedDataPath .build/derived-device -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team id> build
xcrun devicectl device install app --device <iPhone UDID> \
  .build/derived-device/Build/Products/Debug-iphoneos/Scrollar.app
```

The project has no team set, so the team goes on the command line and nothing about signing
is committed. `xcodebuild` can say SUCCEEDED without relinking: when a change does not show,
compare the binary's timestamp with the edit before debugging the code.

In a debug build the simulator can be started without typing anything in:
`SIMCTL_CHILD_SCROLLAR_OPENALEX_KEY=… SIMCTL_CHILD_SCROLLAR_ORCID=… xcrun simctl launch <device> com.andremouraux.scrollar`
(the ORCID only applies when there are no saved settings). The iOS Simulator has no Apple
sentence-embedding model, so it ranks by word counts only and the feed says so; check
embeddings on a real device or with the command line on a Mac. Apple's on-device language
model (summaries) does run in the simulator, through the host Mac.

## Refreshing

A refresh asks only for papers published since the last complete fetch, minus three
days of overlap, and merges them into the papers already held. OpenAlex's "added
since" filters are paid-plan only, so a paper indexed weeks after its publication date
can slip through; the whole window is therefore fetched again every three days, when the
settings change, and after a long absence. `./run.sh <orcid> --compare` runs a full
build and then an incremental one and checks they agree.

## Sources

Two, either of which can be switched off in Tune, and a paper found by both is shown once.

- **Europe PMC** (no key): PubMed and MEDLINE records and the preprint servers.
  Biomedicine only. Answers keywords, journals, MeSH headings (made from your own
  papers' headings when OpenAlex is off), authors and institutions by name, and
  citations of your work, but its citation data is much thinner than OpenAlex's.
- **OpenAlex** (your own free key): every field. Needed for topics, authors by
  id, the impact and h-index options, muting by id, and complete citations.

Without a key the profile comes from Europe PMC alone: the records whose author list carries your
ORCID iD, with abstracts and MeSH headings (for the author's name too). **ORCID's own API is not
used**: its public licence is non-commercial, so the iD is only an identifier, looked up in OpenAlex
or in Europe PMC. `./run.sh <orcid> --no-openalex` tries that path alone; `--no-europepmc` the other.

`Core/Sources.swift` routes each seed to the sources that can answer it, reads
Europe PMC, and `Merge.combine` (in `Model.swift`) is the deduplication:
copies are one paper if they share a DOI, a PMID or an id, or, for a preprint and
the article it became, the same title and first author within eighteen months.
The article, then the OpenAlex copy, is the base, so ids and the DOI history is
keyed on do not change when a preprint is published.

## Sync between devices

One JSON file, chosen once on each device (Tune, Sync between devices), in iCloud Drive.
`Core/Sync.swift` is the whole idea and is tested without a cloud; `App/SyncFile.swift`
is only the file (a bookmark, file coordination, iCloud placeholders, conflict versions).

The unit is a decision: "follow this journal", "save this paper", "daily window = 14".
Each is an entry with the time of its last change and whether it is still there (a
removal is a tombstone, or the other device would put it back). Two files merge entry by
entry, the later change winning, so edits to different things never conflict. Seen and
read only move forward (read beats seen, earliest first sighting, latest last sighting),
so history merges with no conflicts at all.

Shared: follows, mutes, keywords, tracked papers, every setting, saved and hidden
papers, what has been seen and read. Not shared: the OpenAlex key, and the feed, summaries
and embeddings, which each device rebuilds.

How it behaves: the ledger of local decisions (`sync-ledger.json`) is kept beside the
settings; settings that arrive from the other device are recorded before they are applied,
so they are never mistaken for edits made here. A first run stamps existing settings with
the time of the settings file, so a fresh install's defaults never outrank an edited
device. The file is read at launch and on returning to the app, and written a few
seconds after a settings change (a minute after reading, so scrolling does not rewrite
it). A file written by a newer version is neither read nor written, and a file that is
not a sync file is never overwritten.

## Key

OpenAlex is optional. For the command line, copy `Secrets.example` to `Secrets.local` and put
a free key (<https://openalex.org/settings/api>) in it; `Secrets.local` is gitignored and was
never committed. In the app each user pastes their own into Tune, Sources; it lives in the
Keychain, never in the settings file, the sync file or the binary, and is sent only to
OpenAlex. Do not compile a key in.

## Ranking

`Ranker.rank` scores every candidate; the constants and their reasons are in
`Core/Ranking.swift`. In short: similarity to the user's own and saved papers (a percentile
blend, 0.6 Apple embeddings and 0.4 word statistics, against the three nearest papers, so a
researcher with several themes is not averaged into one) times the "stay close to my work"
slider; a bonus for each further seed that found the paper, for citing the user's work and
for being found by something they follow (which matters for topics, institutions and funders, see below); a recency term that halves every fortnight, times
its slider; a small penalty for repository records (not for preprints); the kind adjustment
(case reports and conference abstracts start lowered; hide removes them before ranking); and
the importance the user gave the keyword that found it (High +1.2, Normal 0, Low −0.6; the highest of the keywords that found it); and
two optional terms, off by default: the journal's two-year mean citedness (OpenAlex's
open stand-in for the impact factor, which is Clarivate's) and the h-index of the first, the
last or the higher of the two authors. Both are logarithmic, neutral for a paper with no
figure, and capped. The three ranking sliders only reorder what is held, so moving one costs an
incremental refresh, not a rebuild.

## What the algorithm is, and that it is the user's

Tune is the algorithm, in the open and editable. **Nothing is followed unless it is in a Follow
list**: the app no longer infers topics behind the user's back. The user's publications shape what
"close to my work" means, and can *suggest* follows, which the user chooses (below); the feed is the
follows, the filters and the sliders, each explained under its list.

A follow becomes a search per source that can answer it (`SourceRouting`), returning the newest
papers in the look-back window, up to about 300 per follow per source.

**One ranked list, with a guarantee.** The feed is a single list in score order (`FeedLayout`,
`Core/Layout.swift`), so a paper that cites the user, one a keyword found and one with neither
are interleaved by how well they fit, newest breaking ties, and not shown as three blocks. The
list is cut to the best 150 new papers (60 earlier, 60 read), except that a paper found by a
**journal, a researcher or a keyword** (`Paper.isPinned`) is never cut: it appears however low
it scores, and still passes the user's mutes, filters and the same seen, read and expiry rules.
A **topic, an institution or a funder** is too broad to list in full (each names hundreds of
papers a month, in every field), so what only those found is ranked with the rest and gets +0.8
(and +0.5 for each further search that found it), and a weak match can fall below the cut.
Tune, Order and highlights can instead show the old three sections (cites you, from what you
follow, for you; `Arranger.split`).

**Highlights.** Up to three posts (0 to 5) are lifted into a strip at the top, marked with
an orange outline and the reason in one line. A paper qualifies only if it is very close to the
user's own work (similarity at or above a threshold, 95% by default) **and** has at least one
further sign: it is in a journal whose two-year mean citedness reaches a bar (5 by default), the
author the byline shows has an h-index at or above a bar (40; for First and last the higher of
the two), it cites the user's work, or it comes from a journal, researcher or keyword the user
follows. Setting a bar to 0 ignores that sign. The best by score fill the strip, and a
highlighted paper is not repeated below. Everything in this paragraph is a display choice
(`Highlights.select`): changing it fetches and ranks nothing again.

The user ranks their own keywords: each has an importance (Low, Normal, High; Normal by default),
set in Tune under Keywords. It adds its bonus above to the papers the keyword found, which is
how a High keyword rises in the single list. A paper that a journal or researcher also found is at
least Normal, whatever its keywords say. Journals and researchers are unranked and count as
Normal. A follow never changes the similarity measure, which comes only from the user's own and
saved papers.

## Learning from publications

The ORCID iD under You, and up to three more under Also learn from (a supervisor or group leader:
most useful to a PhD student with few papers), are read for two things. They are the profile that
defines similarity. And they suggest what to follow (`Core/Profile.swift`, `ProfileFetcher.swift`,
`App/ProfileViews.swift`): topics, keywords, journals, co-authors, institutions and funders, each with how many
papers it appears in and the latest year, counted with recent papers weighing more (a weight that
halves about every two years), so what the user still works on comes first. Ticked to begin with:
recent (within four years) and recurrent, at most eight topics, six keywords, six journals and five co-authors
(a keyword needs three papers, a co-author three together); institutions and funders are listed, never ticked, and a very
large general journal (over 100,000 papers) is listed with a warning and unticked, because following
one would list a flood, and so is a keyword that matches 150 or more papers a month (OpenAlex counts
them; "chronic pain" matches about two thousand), which can be followed with conditions added afterwards.
Keywords are the phrases OpenAlex finds in each paper (the strongest six); Europe PMC offers none. Old interests are listed unticked in case the user still follows them. A
consortium paper's authors are ignored as co-authors; repositories are not journals.

The first time, and only then, when the follow lists are all empty and there is an iD, the ticked
suggestions fill the lists (`profileFilled`, synced, so a second device does not repeat it, and
nothing the user removes comes back); a notice says so. After that "Suggest what to follow…" in Tune
shows what is not yet followed, to choose from. Without OpenAlex the same works from the Europe PMC records that carry the
iD (MeSH headings as topics, journals and co-authors by name; no keywords, institutions or funders). `./run.sh <orcid> --suggest [--also <orcid>]` prints the suggestions.

## Reading state

A post is *seen* after a second on screen and *read* when opened. The feed is sorted into new,
earlier and read only when it is loaded or refreshed, never while scrolling, so nothing moves
under a finger; an unrequested refresh waits behind an "N new papers" pill. Seen papers sink
below the new ones and drop out after a week (a setting); read papers leave the feed and are
kept under Saved, Read. `Why.main` picks the one reason shown above a post, the most
specific choice of the user's first (a citation of their work, then a followed author,
keyword, journal, institution, funder, then a topic).

## What a post shows

In this order: a compact banner in the journal's colour (the same colour for a journal everywhere,
with its full name, its subject, when, and a symbol; a setting turns it into a plain line), then the whole
title as the biggest type on the card, one or two sentences of what the paper shows, the first
and/or last author with their institution (and the impact and h-index while those options are on), and
the reason it is there, then the buttons. Those sentences are written on the device by Apple's language model where
there is one (`App/Summarizer.swift`: on-device only, one paper at a time, started when a post
has stayed on screen and cancelled when it leaves, cached in `summaries.json`, held to two
sentences in code because the model sometimes writes five); otherwise they are chosen from the
abstract's own sentences (`Summary.takeaway`), never cut mid-sentence. A model-written line is
labelled as such when the post is opened.

## Tune

Everything the user can enter is in `Core/Settings.swift`, with what each does: ORCID, up to three others to learn from, and whether
to learn from publications; sources; follows (topics, journals, researchers, institutions,
funders, keywords with their own must-also and must-not conditions) and tracked papers; mutes
(journals, researchers, topics, words); a weight (hide, lower, normal, boost) for each kind of
paper; look-back days; the three ranking sliders and which author counts; only papers with an
abstract, only open access, languages; how long to keep unread papers and whether to show read
ones; which author heads a post and whether to show the journal banner. Settings are decoded
tolerantly: a missing, unknown or mistyped key falls back to its default and only a file that is
not JSON fails, in which case it is copied aside and never silently replaced.

## The Mac build

Mac Catalyst, sandboxed (`Scrollar-Mac.entitlements`, applied to the Mac SDK only): network
client, and user-selected read-write files with app-scoped bookmarks for the sync file. Commands:
Cmd-R refreshes, Cmd-1/2/3 switch tabs. Its data lives in its own container, so nothing is shared
with the phone except through sync. It builds, is signed and runs; its window has not been
checked on screen, and saving the key to the Keychain from the sandbox is untested.

## Not built, and why

- **Real article figures on posts**: measured on a 1,453-paper feed, only about 3% of papers had a
  figure that could be shown (open-access full text, large enough, CC BY or similar, no credit
  line), under 1% if limited to graphical abstracts and schematics. Europe PMC's full text
  failed most requests and refused its image files to scripts; the one reliable route was the
  PMC open-access dataset on AWS. Not worth the machinery. The journal banner stays.
- **PubMed searched directly**: Europe PMC returns the same MEDLINE records with abstracts,
  publication types and MeSH in one request, and the preprint servers too. PubMed itself is used
  to fill missing abstracts and types.
- **Author photographs and institution logos**: open scholarly data has none that can be reused;
  initials on a colour stand in.
- **Background refresh and notifications**, a three-column layout for Mac and iPad (feed, a
  reader pane, a sidebar of follows with counts), and Crossref or arXiv as sources for fields
  outside biomedicine are proposed and not started.

## Known gaps

Citations of your work are thin without OpenAlex (Europe PMC knows far fewer). Without OpenAlex the
profile is only the papers where Europe PMC has linked the author's iD (174 of the 203 works the
author's ORCID record lists), and recent papers have no MeSH headings yet, so topics lean older. Sync has been
checked with a local file standing in for iCloud Drive, not with iCloud itself. Pull-to-refresh once
failed to start in the simulator and was not reproduced. The summary sentence chosen without the
model is a heuristic and is sometimes background, not a finding.

## Layout

- `Core/`: Foundation only except where noted, and tested by `Tests/run.sh`, which compiles
  these files (not the network files) with `Tests/main.swift`. Anything worth testing belongs
  here, not in a view.
  - `Model.swift` (`Paper`, identifiers, `Merge.combine`, the deduplication), `Kind.swift`
    (article, review, case report, conference abstract, preprint, commentary), `Seed.swift`,
    `Ranking.swift`, `FeedBuilder.swift` (what to ask for, and what to keep), `Engine.swift`
    (settings in, ranked feed out; the app and the command line both call it).
  - `Settings.swift`, `History.swift`, `Incremental.swift`, `Sync.swift`, `Sources.swift`
    (routing, Europe PMC parsing), `Summary.swift`, `Byline.swift`, `Why.swift`,
    `Cover.swift`, `Layout.swift` (the single ranked list and the highlights), `PubMed.swift`, `Profile.swift` (the ORCID check, and suggestions from publications).
  - Network and Apple frameworks, each in one place: `OpenAlex.swift`, `EuropePMCClient.swift`,
    `PubMedClient.swift`, `ProfileFetcher.swift` (a person's papers, for the profile and its suggestions), `Embedding.swift` (NaturalLanguage).
- `App/`: SwiftUI. `AppModel` holds the state, `Store` the files and the Keychain,
  `SyncFile` the sync file, `Summarizer` the on-device model, `FeedView`, `SavedView`, `SettingsView`, `ProfileViews` (others to learn from, and the suggestions sheet).
- `Design/`: the icon. `AppIcon-source.webp` is the artwork (a transparent background); `make-icon.swift`
  puts it, enlarged and centred, on an opaque background and writes the 1024-pixel PNG in
  `App/Assets.xcassets/AppIcon.appiconset` (`swiftc Design/make-icon.swift -o /tmp/icon && /tmp/icon Design/AppIcon-source.webp App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`).
- `CLI/main.swift`: the command-line driver. `Tests/`: the checks and their runner.

Every seed (a topic, journal, author, keyword, or "cites my work") becomes one query per source
that can answer it. Results are merged, ranked, and each post keeps the reasons it appeared.
