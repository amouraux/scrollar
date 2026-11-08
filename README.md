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
list is not cut: it goes as far down as the papers held (the earlier and read lists are limited to 60
each), so a paper found by a **journal, a researcher or a keyword** (`Paper.isPinned`) always
appears, however low it scores, and still passes the user's mutes, filters and the same seen, read
and expiry rules. Past the end of it the feed goes on (see Endless scroll). In the sections order the
"For you" list is still limited to 150.
A **topic, an institution or a funder** is too broad to list in full (each names hundreds of
papers a month, in every field), so what only those found is ranked with the rest and gets +0.8
(and +0.5 for each further search that found it), and a weak match sinks to the bottom.
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
Normal. A keyword can require other words (all of them) and exclude some. The required words go to the
sources with the phrase ("pain" AND "EEG"), so a broad phrase is not cut to its newest 300 papers
before they are checked; exclusions are checked afterwards. The same phrase may be followed more than once,
each with its own words: the rules of a phrase are alternatives, so "pain" with EEG and "pain" with
MRI find papers that have either. Each rule is its own search and its own reason on the card
("Keyword: pain + EEG"), with its own importance, and is synced by an id, not by the phrase
(`KeywordRule.id`; a rule saved earlier takes its phrase). A follow never changes the similarity measure, which comes only from the user's own and
saved papers.

## Preview, and backup

**Preview.** Following something blind is how a broad keyword floods a feed, so Tune can show what a
follow finds before and after it is kept (`Core/Preview.swift`, `FeedEngine.preview`). Open a keyword
and choose "Preview the papers it finds"; tap any topic, journal, researcher, institution or funder in
its list; or tap the eye beside a search result before adding it. It asks each source that can answer
for one page (100) over the look-back, applies the same words, mutes and filters as the feed
(`FeedBuilder.keep`), and shows the newest 30, how many there are ("or more" when a source returned
a full page), and how many the keyword's own words, mutes or filters removed. Nothing is stored and
nothing is followed. Topics need OpenAlex and its key, and say so when they cannot be asked.

**Backup.** Tune, Backup saves the settings to a file you keep (`Core/Backup.swift`) and restores one,
after showing what it holds and asking. It holds the follows, mutes, keywords, sliders and the saved
and hidden papers; never the OpenAlex key (a credential), the feed (a cache) or what was read. A file
that is not a backup, such as the sync file, is refused, because decoding it leniently would replace the
settings with defaults; one from a newer app is refused too. Restoring is an ordinary edit, so with
syncing on the other devices follow. It is a snapshot to go back to; the sync file is what keeps devices
together.

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

## Endless scroll

The feed holds the look-back window (30 days by default). Scrolling to the end of it brings a
footer into view, and the footer fetches the 30 days before the ones held (`Incremental.olderRange`,
`FeedEngine.build(older: true)`): the same follows, the same sources, bounded by a start and an end
date, merged into what is held. The papers appear below, under "Further back", and the footer fetches
the next 30 days while it is still on screen, until a year is held. Three rules keep the list from
moving under a finger. Further back is always last among the new papers, whatever it scores. It is
ordered by the 30-day step it came from, nearest first, and by score within a step, so a better
paper fetched later never lands above one already scrolled past. And highlights come only from the
look-back. Going back does not touch the record of how recent the feed is, so the normal refreshes
carry on as before. A full rebuild (every three days, or when a follow or filter changes) fetches
the look-back only and forgets the extra days; scrolling to the end fetches them again. A failed fetch
leaves a button, "Try again", and does not retry by itself. The extra days are kept in the feed cache
(`CachedFeed.extraDays`), not in the settings, and cost requests like any refresh: with OpenAlex that is
per follow, up to three pages, for each 30 days.

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

## The reader pane

A window at least 780 points wide (a Mac window, an iPad in landscape or portrait; `Reader.isWide`) puts
the feed in a column of about 38% of the width, 340 to 460 points, with a reader pane to its right.
The line between them is a handle: drag it to move the split, double-tap it to go back to the default
(VoiceOver can adjust it too). The width is remembered as a fraction of the window, so resizing the
window keeps the proportion, and it cannot be dragged so far that the feed falls under 320 points, the
pane under 380, or the feed past 700 (`Reader.feedColumnWidth`). There is no resize cursor on the Mac:
SwiftUI's `pointerStyle` is not available to Mac Catalyst. A
narrower window (an iPhone, an iPad mini, a thin split) is the single column it always was: tapping a
post unfolds its abstract in place and nothing else changes. The same view tree serves both, so
resizing a window keeps the feed's scroll position.

Tapping a post in the wide layout shows the paper in the pane instead of unfolding it, and the post
is outlined in the accent colour. The pane has the journal in its colours, the whole title, every
author up to twelve (more shows the first eleven, how many are left out, and always the last author)
with the first and last marked and their institution and h-index where the open data has them, every
reason it is in the feed (and why it is a highlight), the abstract, the journal's impact, how often it
is cited, open access, topics, the DOI link, and Save, Not for me, Open and Share in a bar that stays
in view. The posts lose their Abstract button there, since the pane is the abstract.

Opening a paper in the pane counts as read, exactly as opening its abstract does on a phone
(`AppModel.openInReader` calls `markOpened`), and nothing else does: the feed is still only
re-sorted on a refresh, so the post stays where it was. Not for me on the open paper moves the pane to
the one that took its place. Cmd-] and Cmd-[ step through the feed in the order it is drawn
(`FeedLayout.displayOrder`, tested against the layout) and scroll the post into view; they are off
while the pane is not on screen, so no paper is marked read where nobody could see it. The pane shows
the open data's figures, not pictures: there are still no article figures (see Not built).

**PDF.** A paper with a free PDF gets a Details | PDF switch above the pane, and a "Free PDF" link
under Link. The address comes from the sources, never guessed: OpenAlex's best open-access location
(else the publisher's own PDF link) and Europe PMC's full-text list, taking only a PDF marked open
access or free, and only https (`PDFLink`, `Paper.pdfURL`). The file is downloaded when the PDF side
is opened (not before), checked to begin `%PDF-` and to be under 80 MB, and shown with PDFKit; a
site that answers with a web page or an error (a paywall, a cookie wall, a bot check) gets a message
with Try again and Open in browser rather than a blank pane. Many publisher links do that, so the PDF
side shows what the open-access copy allows, not every paper. Papers cached before the field existed
have no link until the next full build (every three days, or when a follow changes). The PDF is held
in memory only while that paper is open and is not saved. There is no pane on a phone, so there is no
PDF view there; Open still sends it to the browser.

## Reference managers

Share on a post or in the pane is a menu: **Share link**, or **Share reference (.ris)**. The second
sends a `.ris` file (named for who, when and what: `Legrain-2026-Cortical-gamma-responses.ris`),
which Zotero, EndNote, Mendeley, Papers and Citavi all import; from the share sheet that is Save to
Files, or Open in the manager's own app. RIS is the one format all of them read, which is why this
needs no account, key or network, and nothing is sent anywhere by Scrollar itself. The file is made at
the moment of sharing (`ReferenceFile`), not when the button is drawn.

The record (`Core/RIS.swift`, tested) has the type (journal article, or conference paper), authors as
"Last, First", title, journal, year and date, abstract, DOI, PMID, the link, the topics as keywords
and the language, one value per line with CRLF line ends. Names arrive two ways, "Valéry Legrain"
(OpenAlex) and "Legrain V" (Europe PMC: surname, then initials); both are read, and a particle stays
with the surname ("van der Berg, Ludwig"). It is a guess for names that follow no pattern, and the
manager lets the user correct one. A preprint is written as a journal article with the server as
the journal, because RIS has no preprint type that every manager reads.

Saved and Read each have an **Export** button for the whole list. A paper saved before authors and
the journal were kept (`SavedPaper.authors`, `.journal`, optional, so older entries and older apps
are unaffected) has only a title, abstract, date and DOI; the export fills the rest from the feed
where the paper is still held, and otherwise leaves them out. Papers saved from now on keep them.
The EndNote desktop app and the mobile apps open the file by tapping it; I could not test any of the
managers here (the simulator has none), only the file itself, which is checked in `Tests/main.swift`
and by reading what the app wrote.

## Zotero

Tune, Zotero library connects an account with an API key made at zotero.org/settings/keys. The
key is checked with Zotero (`GET /keys/current`, which says whose it is and whether it may write),
kept with that answer in the Keychain, and sent only to api.zotero.org, in a header, never in an
address, a log line or an error. It is not a setting, so it is in no sync file or backup.

**Learning from it.** The newest items added (not modified: `sort=dateAdded`) are read, title,
abstract and the user's own tags, and join the profile that defines "close to my work", exactly as
saved papers do, so a paper is judged against what the user is filing now. How many count is a setting
(10 to 500, 100 by default); old interests fade because only the newest are used. Nothing is
followed because of it: Follow lists stay the user's, and it changes only how what is held is ranked,
so switching it on costs a re-rank, not a rebuild (`FeedSettings.useZotero`, `zoteroRecent`, both
synced; `forFetching` ignores them). The texts are embedded on the device; what leaves it is the
request to Zotero. A library is read on each refresh but costs one request when nothing changed:
Zotero answers "not modified" to `If-Modified-Since-Version` and the copy in the caches
(`zotero.json`) is used, which is also what ranks when Zotero cannot be reached (and the feed says so
when there is no copy). Going further back asks Zotero for nothing. Attachments, notes and untitled items
are skipped; an item with no abstract still counts by its title and tags.

**Saving to it.** With an account connected, the Share menu on a post and in the pane has Save to
Zotero. It checks the DOI against the library first ("Already in your Zotero library"), then posts the
paper as a journal article (a preprint or conference paper with its own type and venue field) with its
authors, abstract, DOI, link and topics as tags, under a write token so a retry cannot make two. A key
that can only read says so before anything is sent. The PDF is not attached; Zotero's own Find
Available PDF does that. The answer shows briefly over the feed.

Not built: group libraries (only the account's own), filling a missing abstract from the DOI, suggesting
follows from the library's tags, and EndNote or Mendeley, for which there is no reading API I could
use (the RIS export covers writing to them). The client is tested against a stub that answers instead
of the network; a real library has not been read here.

## Tune

Everything the user can enter is in `Core/Settings.swift`, with what each does: ORCID, up to three others to learn from, and whether
to learn from publications; sources; follows (topics, journals, researchers, institutions,
funders, keywords with their own must-also and must-not conditions) and tracked papers; mutes
(journals, researchers, topics, words); a weight (hide, lower, normal, boost) for each kind of
paper; look-back days; the three ranking sliders and which author counts; only papers with an
abstract, only open access, languages (an "English only" switch, or a list of codes); how long to keep unread papers and whether to show read
ones; which author heads a post and whether to show the journal banner. Settings are decoded
tolerantly: a missing, unknown or mistyped key falls back to its default and only a file that is
not JSON fails, in which case it is copied aside and never silently replaced.

## The Mac build

Mac Catalyst, sandboxed (`Scrollar-Mac.entitlements`, applied to the Mac SDK only): network
client, and user-selected read-write files with app-scoped bookmarks for the sync file. Commands:
Cmd-R refreshes, Cmd-1/2/3 switch tabs, Cmd-] and Cmd-[ open the next and previous paper in the reader pane. Its data lives in its own container, so nothing is shared
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
- **A left column** for the wide window (Saved, Read, Tune, or a list of what is followed, with
  counts): the feed and the reader pane were what was asked for, and the tabs still do the rest.
- **Background refresh and notifications**, and Crossref or arXiv as sources for fields
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
    `Cover.swift`, `Layout.swift` (the single ranked list and the highlights), `Reader.swift` (when there is room for the pane, what it lists, and which paper comes next), `PubMed.swift`, `Profile.swift` (the ORCID check, and suggestions from publications).
  - Network and Apple frameworks, each in one place: `OpenAlex.swift`, `EuropePMCClient.swift`,
    `PubMedClient.swift`, `ProfileFetcher.swift` (a person's papers, for the profile and its suggestions), `Embedding.swift` (NaturalLanguage).
- `App/`: SwiftUI. `AppModel` holds the state, `Store` the files and the Keychain,
  `SyncFile` the sync file, `Summarizer` the on-device model, `FeedView`, `ReaderView` (the pane), `SavedView`, `SettingsView`, `ProfileViews` (others to learn from, and the suggestions sheet).
- `Design/`: the icon. `AppIcon-source.webp` is the artwork (a transparent background); `make-icon.swift`
  puts it, enlarged and centred, on an opaque background and writes the 1024-pixel PNG in
  `App/Assets.xcassets/AppIcon.appiconset` (`swiftc Design/make-icon.swift -o /tmp/icon && /tmp/icon Design/AppIcon-source.webp App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`).
- `CLI/main.swift`: the command-line driver. `Tests/`: the checks and their runner.

Every seed (a topic, journal, author, keyword, or "cites my work") becomes one query per source
that can answer it. Results are merged, ranked, and each post keeps the reasons it appeared.
