# Scrollar

A feed for researchers: scroll through new papers from the journals, topics,
people and keywords you follow, ranked by how close they are to your own work.

Status: working prototype, used daily on an iPhone. One SwiftUI app for iPhone, iPad and
Mac (Mac Catalyst), on top of a tested core that also runs from the command line. Screens:
Feed, Reading list (with Read and For me), and Tune, which holds everything that shapes the feed.

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
sentence-embedding model; the app then falls back to Apple's contextual model (see "Without Apple Intelligence"),
and says in Tune which one ranked the feed. Check embeddings on a real device or with the command line on a Mac. Apple's on-device language
model (summaries) does run in the simulator, through the host Mac.

## Refreshing

A refresh asks only for papers published since the last complete fetch, minus three
days of overlap, and merges them into the papers already held. OpenAlex's "added
since" filters are paid-plan only, so a paper indexed weeks after its publication date
can slip through; the whole window is therefore fetched again every three days, when the
settings change, and after a long absence. `./run.sh <orcid> --compare` runs a full
build and then an incremental one and checks they agree.

## Sources

Five, each of which can be switched off (arXiv and OSF are off until they are switched on) in Tune, and a paper found by more than one is shown once. Crossref, arXiv and OSF are described last.

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

A post is *seen* once it has been in front of the reader long enough, *studied* if it was looked at
for the user's own number of seconds (4 by default, 2 to 15, Tune: Studied after), and *read* when opened.
Time is counted only while at least half the post is on screen and the app is active, and adds up over visits
(`DwellTracking`, `History.addDwell`); from iOS 18 the scroll view reports the visible share, earlier the
post's appearance stands in for it. Under 1.5 seconds a post was passing through: it stays **new**. Between
that and the studied threshold it is **glanced**: it sinks below the new ones and drops out after a week
(a setting). **Studied** sinks below the glanced ones and drops out after two days at most
(`Dwell.studiedExpiryDays`), since the user has looked at it properly. A history file from before dwell was
measured is read as glanced. None of this reads a post as *read*: that stays the user's act of opening it,
and read papers leave the feed and are kept under Reading list, Read. The feed is sorted only when it is loaded
or refreshed, never while scrolling, so nothing moves under a finger; an unrequested refresh waits behind an
"N new papers" pill. The seconds are display-only like the highlights: changing them fetches and ranks nothing.

**For me.** Beside Read later and Not for me, For me says "this is the kind of paper I want" without adding it to the reading list, for a
paper the user knows already. It adds the paper to the profile exactly as saving does (`Feedback.liked`,
synced as `lk/` entries), counts the paper as studied so it leaves the top at the next refresh, and shows a
short confirmation. It is a toggle on the post and in the pane; taking it back removes it from the profile
(not from the history). The Reading list tab has a "For me" list, the only place to take it back once the post has
left the feed, and exports it as RIS like the others. It teaches similarity only: it does not yet favour that
paper's journal or authors.

Sync format is now 2: an older app leaves the file alone instead of erasing the entries it does not know
(it would otherwise mark `lk/` and the Zotero and dwell settings as removed). Update every device that syncs. `Why.main` picks the one reason shown above a post, the most
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
is cited, open access, topics, the DOI link, and Read later, Not for me, Open and Share in a bar that stays
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
which Zotero, EndNote, Mendeley, Papers and Citavi all import; from the share sheet that is Add to
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

Reading list and Read each have an **Export** button for the whole list. A paper saved before authors and
the journal were kept (`SavedPaper.authors`, `.journal`, optional, so older entries and older apps
are unaffected) has only a title, abstract, date and DOI; the export fills the rest from the feed
where the paper is still held, and otherwise leaves them out. Papers saved from now on keep them.
The EndNote desktop app and the mobile apps open the file by tapping it; I could not test any of the
managers here (the simulator has none), only the file itself, which is checked in `Tests/main.swift`
and by reading what the app wrote.

## PDF storage, and reaching each reference manager

**Downloaded PDFs are kept** in the app's Caches folder (`App/PDFCache.swift`), so a paper opens again at
once and without a connection. Tune → Downloaded PDFs shows the space used, a limit (200 MB to 2 GB,
or none; 500 MB by default) and Clear. When the limit is passed the least recently used go first, and
the PDFs of papers you saved only after every other (`Core/PDFCachePlan.swift`, tested). The system may
also empty Caches by itself; then it is a download again. Only a direct download is kept: a PDF shown by
the web view fallback is not a file the app holds.

**Sharing PDFs between devices.** Tune → Share PDFs between devices takes a folder the user chooses, in
iCloud Drive, the same one on each device (`App/PDFFolder.swift`). A device looks there after its own
cache and before the network, copies what it finds into the cache, and puts PDFs there: those of
papers saved or marked For me, or every PDF opened, as chosen. I chose a folder over iCloud's own app
container (CloudKit or a ubiquity container) because that needs an iCloud entitlement, a container and
a provisioning change I cannot verify from here; a folder works the way the sync file already does,
through a bookmark and file coordination, and the files stay visible and deletable in Files. They are
named after the paper with a tag the devices compute the same way, so they are found by the tag. Nothing
trims or deletes in that folder (it is the user's iCloud space); the local limit does not apply to it.
It is untested against a real iCloud Drive, only built.

How each manager is reached, and why:

- **Zotero** has a real write interface, so with an account connected (Tune) Add to Zotero creates the
  item with its full metadata, in the collection chosen there (or one named Scrollar that the app can
  create), and attaches the PDF: the kept copy, or a direct download made at that moment. The file
  goes into Zotero's own storage and counts against its quota (300 MB free); if it is full or too
  large the item is still saved and the message says the PDF was not. Without an account, the share sheet's link or
  PDF goes to the Zotero app, which has its own importer.
- **EndNote** has no way in from outside the app, but opens its own `.enw` import format with a tap or
  a double-click, so the menu offers that (`Core/EndNote.swift`). Its RIS import works too, through a
  menu. I could not run EndNote here: the file is checked against the format, not against EndNote.
  EndNote (and Mendeley) can also import PDFs from a folder by themselves, so Tune → Reference manager
  folder takes that folder and a paper's Share menu gets "Put the PDF in it" (`WatchedFolder`); the
  manager reads the details from the PDF, so for a paper without a DOI the `.enw` is better. It will not
  drop a PDF twice, counting EndNote's own Import subfolder. "Copy the PDF" puts the file on the
  clipboard under a readable name and "Copy the reference as text" puts the RIS text there (Zotero's
  Import from Clipboard reads it). The clipboard is the one route that every app can receive, but only
  an app that accepts a pasted file or text takes it: I do not know that EndNote does, and Zotero and
  Mendeley take files better by drag or by the folder. None of this was tried against the managers.
- **Mendeley** has a web interface only for an app registered with Elsevier and signed in with OAuth,
  which is not something to ask of a reader, and I found no endpoint that reads RIS. So: the `.ris`
  file and the PDF, which its import and drag-and-drop take. Tell me if you want a registered-app
  route anyway.

The pieces I could only test against a stand-in for Zotero (`Tests/main.swift`, the whole upload
sequence); I have not saved to a real Zotero library from here.

## Submitting a beta (TestFlight)

What the app already does for review: no accounts, purchases, tracking or private API; HTTPS only; no
third-party code; all four iPad orientations; a privacy manifest (`App/PrivacyInfo.xcprivacy`,
declaring UserDefaults `CA92.1` and file timestamps `C617.1`, no collected data, no tracking);
`ITSAppUsesNonExemptEncryption` = NO (only the system's HTTPS, plus hashing); the Mac build is
sandboxed with the network and user-selected-file entitlements it needs.

What is left for App Store Connect, which only the account holder can do: a public privacy policy
address (`PRIVACY.md`, which the public repository serves), the App Privacy answers, the beta description, a feedback
email, and the age rating. Archive with the released Xcode and a new build number each time:

```sh
xcodebuild -project Scrollar.xcodeproj -scheme Scrollar -configuration Release \
  -destination 'generic/platform=iOS' -archivePath Scrollar-ios.xcarchive \
  DEVELOPMENT_TEAM=<team> CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD) archive
```

then Distribute App → App Store Connect → Upload in the Organizer (it needs an Apple Distribution
certificate). Use the same command with `-destination 'platform=macOS,variant=Mac Catalyst'` for the Mac.
I archived both here to check the plist, the manifest and the entitlements; I did not upload.

### The OpenAlex key, as the screen shows it

Tune, Sources says what the key is doing instead of leaving a masked field to be read. With a key stored it shows the key's last
four characters, Replace and Remove, and "Saved on this device and in use". With none, a field and Save key (the key is
saved when Save key is pressed, not on every keystroke), and "No key: OpenAlex is skipped, and only the other sources answer",
which is what happens when the OpenAlex switch is on and there is no key; the top screen then says "OpenAlex (no key)".
Every save to the Keychain is read back, and a device that would not keep an item (a Mac build with no provisioning profile has
no keychain access group) is told so, in red, for the OpenAlex key, and in a message for the Zotero and the Claude or ChatGPT keys,
instead of the key being lost at the next launch without a word. A debug build in the simulator may use a key from the
`SCROLLAR_OPENALEX_KEY` environment variable, and the screen says so. Tried on the iPhone simulator: no key, a key stored and shown
masked, and removed. The refused-save message has not been seen, because no device here refused.

### Crossref and arXiv

- **Crossref** (no key, `Core/Crossref.swift`): every DOI from every publisher. Asked **only when OpenAlex is off**, as
  the keyless way outside biomedicine. It can search a phrase in *titles* (it has no abstract search; about a third of
  records carry an abstract), a journal by its name and an author by their name, and nothing else: not citations,
  institutions, funders or topics. Crossref ranks by loose likeness, so every record is checked: a phrase must be in the
  title or abstract, a journal's name must be the one asked for, an author's name must match one on the paper. A month-only
  date takes the exact day the DOI was registered when it falls in the same month. A paper is called open, with a PDF, only
  where a Creative Commons licence says so. Requests are spaced a second apart, and a "too many requests" answer is waited out.
- **arXiv** (no key, `Core/Arxiv.swift`): physics, mathematics, computer science, statistics and quantitative biology, with the
  abstract, the day a paper is posted. A phrase in titles and abstracts, and an author's words. It is off until switched on.
  Its terms allow one request in three seconds, so all calls go through one gate; the version is not part of a paper's id
  and its own DOI (10.48550/arXiv…) makes it the same paper as OpenAlex's copy. It says: Thank you to arXiv for use of its
  open access interoperability.
- **OSF preprints** (no key, `Core/Osf.swift`): the Open Science Framework's servers (PsyArXiv, SocArXiv, EdArXiv, OSF Preprints and
  more), which matter most in psychology and the social sciences. Off until switched on. A phrase in titles and abstracts, nothing
  else (contributors cannot be searched; a keyword's further words are checked after). Each version of a preprint has its own
  record, so the newest is kept and the DOI is given without its version, which makes it the same paper as another source's copy.
  A date bound has to say the end of the day (`T23:59:59`) or everything posted on the last day is missed: found by trying it on the
  real service, where a paper posted that day was missing until then. Europe PMC carries some PsyArXiv papers, not all: of two
  pain preprints from one week it had one. Run against the real service from the app's own client: a phrase gave eight
  PsyArXiv and SocArXiv preprints with abstracts and authors.
- No contact address is sent: the requests say "Scrollar" and the project's web page. Crossref gives a faster pool to requests
  that carry an email address; I did not put one in, because it would be sent from every user's device.
- Tried against the real services here, from the code that the app uses: a phrase, a journal and an author on Crossref
  and a phrase and an author on arXiv returned what they should (45 papers for "chronic pain", only the journal asked for).
  The app itself has not been run with them switched on in a real feed.

## Filtering what you kept

Reading list, For me and Read share a **Filter** panel (the button at the top right; on a wide window it
sits beside the list, on a narrow one it opens as a sheet). It groups the list by why each paper
reached your feed, the same reasons the posts show: cites your work, an author you follow, a keyword,
a journal, an institution, a funder, a topic you follow, a topic from your own papers. Under a kind
are the names within it (which author, which topic) with a count; choosing one filters the list,
choosing it again clears it. Sort by latest kept, publication date, or relevance to me (the most
specific reason first, then papers with more reasons), and search by title, author or journal. Each
row says its top reason. Export always takes the whole list, whatever the filter shows.

A saved paper now keeps its reasons (`SavedPaper.reasons`, `.followed`, optional, so older entries
and older apps are unaffected, and the sync format is unchanged). Papers kept before this get them
from the feed while it still holds the paper, and are listed under Other otherwise; they are not
guessed. The logic is `Core/SavedFilter.swift`, tested in `Tests/main.swift`. I checked the panel on
the iPad simulator with made-up saved papers; the Mac window itself I only built.

## Without Apple Intelligence

Apple Intelligence is not switched on everywhere (not on iPhones in the EU, at the time of writing), and
the app must not depend on it. Two different things were behind one banner, and they are now separate.

**Matching** (how close a paper is to the user's work) never needed Apple Intelligence: it uses an
on-device text model. `TextEmbedders.best()` takes Apple's sentence model where the device has one, else
Apple's **contextual** model (`NLContextualEmbedding`: 512-dimension vectors, about 25 ms a text on a Mac,
tried here with related and unrelated abstracts and ranking them correctly), which is a downloadable language asset
and not an Apple Intelligence feature; it is fetched once, on first use. Only if neither can be loaded does ranking
fall back to word counts, and the line under the feed says so. The two models' vectors are not comparable, so the
vector cache records which model made it (`CachingEmbedder.modelKey`) and is never read by another; a
cache from before this, which came from the sentence model, is read as that. Tune, Summaries and matching,
says which model is in use. Not tested on a real EU iPhone: here the contextual model was run on a Mac and the
app's fallback path was built, not exercised on a device that lacks the sentence model.

**Summaries** (the sentence under each title) need a language model. Where the device has Apple's, it is used and
nothing leaves the phone. Otherwise the user can set up an account of their own in Tune (`Core/RemoteSummary.swift`):
**Claude** (Anthropic's messages API; default model `claude-opus-5-5`, low effort, no sampling settings, which
current models reject, and room for thinking) or **ChatGPT** (OpenAI's chat completions; default `gpt-4o-mini`),
the model name editable. It is an API key, a separate pay-per-use account, not a chat subscription, which an app
cannot use; the screen says so, with the cost (a fraction of a cent to a cent or two per takeaway, far less with a
small model such as `claude-haiku-5-5`) and what is sent (the title and abstract of papers that stay on screen, and
nothing else). The key is tried once with a sample abstract before it is kept, lives in the Keychain, goes only to
that service, and is in no sync file or backup. A hard limit of 200 summaries per launch, three at a time, each kept
in `summaries.json` so a paper is asked for once, stops a loop or a long scroll becoming a bill; a refused key is
said once and not retried for every paper. When there is no key and no model, the sentence is still chosen from the
abstract's own sentences. Not tried against the real services here: the requests, the answers and the failures are
tested against a stub.

## Library file and pasted references

EndNote, Mendeley, Papers, Citavi and others cannot be read directly, but all write RIS or BibTeX. Tune,
Library file takes either (`Core/LibraryImport.swift`, tested), by **Paste references** (a sheet that says live how
many papers it found) or by choosing a file. It reads RIS records and BibTeX entries (nested braces, `@string`,
quotes or parentheses, LaTeX accents, UTF-8, UTF-16 and Windows-1252) and, for a rough paste, a list of references
or of titles, one per line or separated by blank lines: Vancouver- and APA-style references give their title and
DOI, a quoted title is taken as it is, a bare DOI is left out because it says nothing about the paper. The
items feed the profile exactly as Zotero's do (`useLibraryFile`, `zoteroRecent`, both synced, re-rank without
fetching). An export has no date added, so an item that was not in the last import counts as new today and the
others keep their dates, and items that arrive together are ordered by publication year: paste or import again from time to time
and the newest are the newest. What was read (not the file) is kept in Application Support, because
when each item first appeared cannot be fetched again; it is not synced (do it on each device). Adding
by paste adds to what is held, a paper pasted twice is one, and the cap is 5,000 items.

## Your project

For someone with few papers yet (a PhD student, say), Tune, **Your project** takes the description of what
they are about to work on: paste a grant proposal, a thesis plan or an abstract, or choose a PDF or a text file
(`Core/Project.swift`, tested). It does two things, both on the device. **Ranking:** the text is cut into
passages of a few sentences (line wraps and words split across a line end joined, headings, tables of numbers,
links and reference lists left out, at most 40, spread over the whole text) and they join the profile texts like
a library's items, so a paper close to the project ranks higher. There is no switch: the project is used while
it is pasted, and **Remove it** stops it. **Keywords:** the phrases it keeps returning to are offered in a list
to choose from. It is plain counting, not a model: phrases of two or three words said more than once, with the
words every proposal uses ("project", "work package", "year", "patients") never at an edge, a longer phrase
dropped when it only extends one already offered, and single words (long, at least three times) offered
unticked, because a keyword listed alone is listed in full. Nothing is searched before the choice: the text and
the phrases offered stay on the device, and a keyword is searched only once it is followed, like any other. The
project is kept in `project.json` in Application Support, is not synced and is not in an exported settings
file, because a proposal may be confidential. Replacing or removing it re-ranks the feed without fetching.
Not tried: a proposal in another language than English (the stop words and the sentence model are English),
and the real proposals of anyone but the sample in the tests.

### Several projects, each with a title

Tune, You, Your projects keeps up to ten projects, each with a title the user can change (suggested from the text when its first
line reads as a heading, else "Project 2"), a switch for whether it ranks the feed, its text (shown on request), Suggest keywords,
and Replace the text, which discards the old text for the new and does not merge (the title and the keywords already followed stay).
The passages of the projects in use share one budget of 40, each thinned to its share (`ProjectText.combinedPassages`), so a long
project does not drown a short one. What a project does is only to rank: what is fetched depends on what is followed, which is why
the screen says to follow the suggested keywords. The single project an earlier version kept moves into the list on first launch
(`projects.json`), its title replaced by a plain one where the old title was only the first words of its text. Tried on the
iPhone simulator: the migration, and the list and project screens. Not tried: adding a second project, and the Mac window.

### Asking a language model

Counting cannot tell a topic from a frequent phrase, so **Suggested keywords** can also ask a language model
(`Core/ProjectBrief.swift`, tested; the calls are in `App/ProjectAI.swift`). It is only ever on request, and
nothing is asked or sent when the sheet opens.

- **Apple's on-device model**, where the device has one: it reads an excerpt of about 5,000 characters on the
  device, nothing is sent anywhere (it is the on-device model, never Private Cloud Compute), and the answer is
  read as a list of phrases. Tried on the iPhone simulator, where it answered with sensible phrases.
- **Claude, ChatGPT or another model**, if the user set up their own account under Summaries: the same brief, with an excerpt of up
  to 14,000 characters. Before anything is sent, a screen says that it leaves the device, who receives it
  (Anthropic or OpenAI, under the terms of the user's own account), that the developer receives nothing, and
  that names in the passages are not removed; it shows the exact text and the Send button names the company.
  It is asked every time and nothing is remembered. Not tried against the real services: the request and the
  reading of the answer are tested against a stub.

**Another model.** Beside Claude and ChatGPT, Summaries and AI takes "Other (OpenAI-compatible)": an address, a model name and a key.
It covers any service that speaks OpenAI's chat format (Mistral, which is useful in the EU where Apple's model is not offered,
Gemini's compatible address, OpenRouter, DeepSeek) and a model on the user's own machine (Ollama, LM Studio), which needs no key.
The address must be https; http is allowed only for this device and a private network (`localhost`, `127.0.0.1`, `*.local`, `10.`,
`192.168.`, `172.16`–`172.31`), so nothing goes over the internet in the clear. The warning before project text is sent names the host
that receives it, and says when it is a model on this device or network. A chat subscription (ChatGPT Plus, Claude Pro) cannot be
used: it gives no access to other apps. The Summaries screen now also offers setting up an account on a device that has Apple's model,
which before showed nothing: such an account writes no takeaways there, and is only used, on request, for keywords from a project. An
account set up before this loads as it did. Run against a stand-in for a local model from the app's own client: it asked
`/v1/chat/completions` with the model name and no key header and read the answer. Not tried against a real third-party service.

What goes is the excerpt: passages of the text, evenly spread, without headings, tables, links or reference
lists, plus the instructions that ask for keywords and, for a service, the key in a header. A phrase from a model
is shown with how often the user's own text uses it, and "not in your text" when it supplied the term, so a
suggestion is never taken for a quotation. Phrases of several words are ticked; the user chooses.

Why it is built this way for the App Store: Apple's guideline 5.1.2(i) asks an app to say where personal data
goes when it is shared with a third-party AI and to get permission first, so the consent is per use and shows the
data, not a setting that is on once. The privacy policy names the case, and the optional key and the screen mean
the feature is absent until the user sets it up. Whether this changes the App Privacy answers is for the account
holder to decide: the developer receives nothing, the user's own account does the sending.

## Reference managers, by what each can do

Tune, Reference managers asks which are in use (Zotero, EndNote, Mendeley, "Papers, Citavi and others") and says what each can do. Only
what works for the ones chosen is shown, here and in the Share menu; none chosen shows everything (`Core/ReferenceManager.swift`,
tested). Zotero: the connection, its collection, the PDF, learning from the newest items, and the check of the key. EndNote and
Mendeley: the PDF folder they watch (EndNote's automatic import; Mendeley can watch one), the `.enw` file for EndNote and the `.ris`
file for Mendeley and the others. EndNote, Mendeley and the others: the reference export, as the way to learn from a library
that has no connection (not needed if Zotero is used). A Zotero-only user sees no folder and no export; the Share menu then offers
Add to Zotero, the reference as text and the PDF, and no `.enw`. "Import a newer export" is now "Replace with a newer export": it
takes the file as the whole library, so a paper no longer in it is dropped (those kept keep the date they first appeared); "Add
references by pasting" only adds. Choosing a manager neither fetches nor ranks again.

**PDFs** is its own row: the downloaded PDFs and the shared folder, which now says where it is ("iCloud Drive › Scrollar PDFs"), whether it
is really in iCloud Drive (green) or only on this device (orange), or that none is chosen, and that the choice is per device. The
watched folder says where it is too. Tried on the iPhone simulator: the list, the managers screen and choosing EndNote; not the
Share menu, nor the PDFs screen with a folder set.

## Zotero: what the screen says about the connection

The Zotero block shows the key as dots and its last four characters, who it is connected as, and what was found when Zotero was last
asked: "Checked at 14:02: Zotero accepts the key, and it can read and write" (green), or the error (red), or "Key stored on this
device. Not checked since the app opened", because a stored key proves nothing. **Check the connection** asks Zotero again
(`GET /keys/current`) and takes up what it says, so a key whose access was changed on zotero.org (write added) takes effect
without disconnecting; before, the app only learnt what a key could do when it was first connected. With no key it says "No key
stored: not connected". Tried: the build; not tried against the real Zotero here, nor on the screen.

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

**Adding to it.** With an account connected, the Share menu on a post and in the pane has Add to
Zotero. It checks the DOI against the library first ("Already in your Zotero library"), then posts the
paper as a journal article (a preprint or conference paper with its own type and venue field) with its
authors, abstract, DOI, link and topics as tags, under a write token so a retry cannot make two. A key
that can only read says so before anything is sent. The PDF is not attached; Zotero's own Find
Available PDF does that. The answer shows briefly over the feed.

EndNote and Mendeley: see Library file and pasted references. Not built: group libraries (only the account's own), filling a missing abstract from the DOI, suggesting
follows from the library's tags. The client is tested against a stub that answers instead
of the network; a real library has not been read here.

## The reading list, and Add to Zotero

"Save" meant two unrelated things (a list inside the app, and a copy in Zotero), so each now has its own name and
its own place. **Read later** on a post (an eyeglasses button, "On list" once added) puts a paper on the **Reading
list** tab, like Safari's list, and still teaches the feed what the user wants more of. **For me** and **Not for me**
are unchanged. **Add to Zotero** is separate: it is in the Share menu, in the group "Send to a reference manager", and
in the list itself (swipe a row right, or press and hold or right-click it), whichever of Reading list, Read or For
me it is on. Adding to one never adds to the other, and adding to Zotero does not teach the feed by itself (a library
that is connected already does, through its newest items). Nothing in the stored data changed: the list is still
`feedback.saved`, so a sync file or backup from before reads as it did.

On the Reading list, a paper that has been opened is dimmed and marked "Read", and **Unread only** in the filter
panel leaves those out. The order is not changed. The segments are Reading list, Read and For me. A Zotero key that
cannot write shows "Add to Zotero (the key is read-only)" greyed out, not hidden, and failures are shown for fifteen
seconds and put away by a tap. Older notes in this file may still say "Saved" or "Save to Zotero": they mean these.

## Levels: promoting and demoting by degrees

Follow and mute were all or nothing. Tune, Follow and mute, **Levels** gives each keyword, journal, researcher, topic, institution and
funder one of five levels (`Core/Levels.swift`, tested): **Hide** (removed), **Lower** (ranks lower, −0.6), **Normal** (no effect), **Higher**
(searched for, ranks higher, +0.8) and **Maximum** (searched for and everything it finds is kept in full, however low it scores, +0.4 on top
of the 0.8 a followed paper already gets). A topic, an institution or a funder names hundreds of papers a month, so those stop at Higher, as a
follow of one never was kept in full. The lists give each thing its starting level (a follow of something narrow is Maximum, of something broad
Higher, a mute is Hide); a level the user sets is an override kept beside them, and one equal to the starting level is no override. **With no
override anywhere the feed is exactly what it was.** An override changes four things: what is searched for (below Higher a followed thing is
not; at Higher it is, but its papers are not kept in full; something raised that is not followed is searched for too), what is removed (Hide,
by the paper's own words, topic, journal or author, as a mute does; a mute set to another level is no longer a mute), the ranking (the table
above for each paper that carries the thing, the total held between −1.5 and +2) and nothing else. They sync (sync format 5). Tried on the iPhone
simulator: the screen and the starting levels. Not tried: setting a level and seeing the feed change, nor on a real feed.

## Catching up on one topic

On a window wide enough for the reader (the iPad and the Mac), a panel before the feed lists **why papers are in it**: Cites your work, then
Authors, Keywords, Journals, Topics, each with its names, how many papers carry each and how many of them are new (`Core/FeedFilter.swift`,
tested). Choosing one narrows the feed to the papers that are there for that reason, so a subject can be caught up on; choosing it again, or
Everything, shows all, and a bar at the top of the feed says what it is narrowed to, with Clear. It combines with **New only** ("what is new on
this topic") and with the reading order of the arrow keys. A paper counts once per reason however many of its reasons match; a lone name under a
kind is not listed twice; a paper that no follow found (it came by similarity) is under Other. The button beside All | New collapses the panel
(kept); in a window with room for the reader but not for the panel as well, the same button opens the panel as a sheet. The panel is 250 points,
so a 13-inch iPad in portrait just has room. The phone has neither. Tried on the iPad simulator, seeded with a copy of the iPhone simulator's data:
the panel, and narrowing to Keywords. Not tried: on the Mac window, in dark mode, or collapsed.

## New only

At the top of the feed, **All | New** (with a count). **New** shows only what has not been looked at yet: a paper that has
not been on screen for about a second and a half, which is exactly what the NEW badge means. It is about attention, not
arrival: a paper that came last week and was never reached is new, and one that came ten minutes ago and was looked at
is not. The highlights, what lies further back and the new part of each list stay; what has been glanced at ("Earlier")
and what has been read are left out. It changes what is drawn and the order the arrow keys step through, nothing else. As
the rest of the feed, it does not rearrange while scrolling: a paper looked at drops out at the next refresh. When
everything has been looked at it says so, with a button to show all. The choice is kept (`feedNewOnly`, `Core/Reader.swift`,
tested). Not tried: on the Mac window, and in long use.

## What the thumbs do

**Read later** and **For me** pull the feed toward what is like them; **Not for me** now also pushes it away from what
is like the hidden paper. The rules are in `Core/FeedbackMemory.swift` (tested), the screens in `App/FeedbackScreens.swift`
(Tune, Ranking, Your feedback).

- **Pull.** The title and abstract of each paper on the reading list or marked For me join the profile, as before. They are
  counted as one pool, newest first. Only the newest 200 count (the newest in full, the oldest of those a quarter as much,
  by position), a paper can also lose half its weight every 3, 6, 12 or 24 months (never, by default), and drops out when it
  has faded to a few percent; a strength setting scales them against the user's own papers and library. A paper kept before
  dates were recorded is dated the first time the app opens, so it begins to fade from that day.
- **Push.** A hidden paper keeps its title and abstract with the date (`feedback.hiddenPapers`; the ids in `feedback.hidden`
  are unchanged, so an older app still hides). Each candidate is compared with them by the same two measures as everything
  else, but on one raw scale, so that "closer to what was hidden than to anything the user wants" can be told. Only a paper
  that is, and is also among the closest tenth of the feed to what was hidden, is lowered, by up to 1.0 at the default
  strength (the whole range of closeness is 4), less for an older hide. A hide counts for the newest 100, and halves in weight every 6 months by default.
  What the user follows, and what cites their work, is never lowered. A paper hidden before this existed is only an id and
  teaches nothing. The post says "Lowered: like “…”, which you hid".
- **Seeing it.** Your feedback lists every paper with when it was kept and how much it still counts ("Counts fully", "Counts
  partly", "Fading", "No longer counted"). A paper can be set to be ignored without deleting it, a hidden paper shown again,
  and the screen lists what is pushed down (exact, from the last ranking) and what is pulled up (worked out on the device).
- **Sync.** Hidden snapshots and the settings sync, and the sync format is now 4 (3 added the snapshots; 4 added more settings: the age fade, OSF, the reference managers), so an older app leaves
  the file alone rather than erase what it does not know. Ranking is made repeatable: scores that differ only by rounding noise are ties.
- **Not tried:** the strength and the tenth are first guesses, set from tests on made-up papers and not from a real feed, and
  the effect on the on-screen feed after a hide is only seen at the next refresh.

## Tune

Tune opens on a short list of eight rows, each with a line saying what is set (`App/SettingsView.swift`), and each
row opens its own screen (`App/TuneScreens.swift`). It used to be one scroll of twenty sections; nothing was added or
removed, only grouped. **You**: ORCID, who else to learn from, the project, suggestions. **Follow and mute**.
**Ranking**: order and highlights, kinds of paper, time and balance, what you have told it. **Content and display**:
filters, post header and banner, seen and read. **Reference managers and PDFs**: Zotero, library file, the watched
folder, downloaded PDFs, shared PDFs. **Summaries and AI**. **Sources**. **Sync and backup**. Older notes in this file
name the old sections (Posts, Downloaded PDFs, Summaries and matching...): they are on the screens above.

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
- **A left column** for the wide window (Reading list, Read, Tune, or a list of what is followed, with
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
