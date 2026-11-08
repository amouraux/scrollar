import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok    " : "FAIL  ") + what)
    if !ok { failures += 1 }
}

extension Paper { func withDOI(_ d: String) -> Paper { var p = self; p.doi = d; return p } }

// MARK: identifiers
check(Identifiers.openAlexID("https://openalex.org/W123") == "W123", "short OpenAlex id")
check(Identifiers.doi("https://doi.org/10.1000/ABC") == "10.1000/abc", "DOI is lowercase and bare")
check(Identifiers.doi("") == nil, "empty DOI is nil")
check(Identifiers.pmid("https://pubmed.ncbi.nlm.nih.gov/31415926") == "31415926", "PMID from URL")

// MARK: abstracts
check(Abstract.rebuild(["world": [1], "Hello": [0]]) == "Hello world", "abstract is put back in order")
check(Abstract.rebuild(["a": [0, 2], "b": [1]]) == "a b a", "a repeated word fills every position")
check(Abstract.rebuild(nil) == nil && Abstract.rebuild([:]) == nil, "no abstract stays nil")

// MARK: merging
let a = Paper(id: "W1", doi: "10.1/x", title: "T", date: "2026-10-01", reasons: ["Topic: Pain"])
var b = Paper(id: "W2", doi: "10.1/x", title: "T", abstract: "filled", date: "2026-10-01", reasons: ["Cites your work"])
b.citesYou = true
let merged = Merge.combine([a, b, Paper(id: "W3", title: "Other", date: "2026-10-02")])
check(merged.count == 2, "same DOI collapses to one paper")
check(merged[0].reasons == ["Topic: Pain", "Cites your work"], "reasons add up, in order")
check(merged[0].abstract == "filled" && merged[0].citesYou, "missing fields filled from the duplicate")
check(Paper(id: "W9", pmid: "5", title: "t", date: "d").dedupeKey == "pmid:5", "PMID is the key when there is no DOI")

// MARK: seeds
check(Seed.topic(id: "T1", name: "Pain").filter(since: "2026-10-01") == "topics.id:T1,from_publication_date:2026-10-01", "topic filter")
check(Seed.cites(workIDs: (0..<150).map { "W\($0)" }, label: "x").filter(since: "x").split(separator: "|").count == 100, "cites is capped at 100 ids")
check(Seed.cites(workIDs: ["W1"], label: "x").citesYou && !Seed.keyword("k").citesYou, "only cites seeds mark citesYou")

// MARK: ranking
let today = Ranker.dayString(Date()) // "now" in the same form the data uses
let now = Date()
let profile = [
    "Laser evoked potentials reveal how the brain responds to painful heat stimuli",
    "Nociceptive pain perception and cortical responses in healthy volunteers",
]
func paper(_ id: String, _ title: String, age: Int = 3, repository: Bool = false) -> Paper {
    var p = Paper(id: id, title: title, date: Ranker.dayString(now.addingTimeInterval(-Double(age) * 86_400)))
    p.isRepository = repository
    return p
}
let pain = paper("P", "Cortical responses to painful heat stimuli in volunteers")
let galaxy = paper("G", "Dark matter halos in distant galaxy clusters")
let order = Ranker.rank([galaxy, pain], profileTexts: profile, today: now).map(\.paper.id)
check(order == ["P", "G"], "a paper on your subject outranks one that is not")

var citing = paper("C1", "Dark matter halos in distant galaxy clusters")
citing.citesYou = true
let plain = paper("C2", "Dark matter halos in distant galaxy clusters")
check(Ranker.rank([plain, citing], profileTexts: profile, today: now).first?.paper.id == "C1", "a paper citing you rises to the top")

var twice = paper("S1", "Dark matter halos in distant galaxy clusters")
twice.reasons = ["a", "b"]
var once = paper("S2", "Dark matter halos in distant galaxy clusters")
once.reasons = ["a"]
check(Ranker.rank([once, twice], profileTexts: profile, today: now).first?.paper.id == "S1", "found by two seeds beats found by one")

let fresh = paper("F", "Dark matter halos in distant galaxy clusters", age: 1)
let stale = paper("O", "Dark matter halos in distant galaxy clusters", age: 40)
check(Ranker.rank([stale, fresh], profileTexts: profile, today: now).first?.paper.id == "F", "newer beats older when all else is equal")

let repo = paper("R", "Dark matter halos in distant galaxy clusters", repository: true)
let jour = paper("J", "Dark matter halos in distant galaxy clusters")
check(Ranker.rank([repo, jour], profileTexts: profile, today: now).first?.paper.id == "J", "repository records rank below journal articles")

var preprint = paper("PP", "Dark matter halos in distant galaxy clusters", repository: true)
preprint.openAlexType = "preprint"
let zenodo = paper("ZN", "Dark matter halos in distant galaxy clusters", repository: true)
check(Ranker.rank([zenodo, preprint], profileTexts: profile, today: now).first?.paper.id == "PP", "a preprint is not penalised as a repository record")

check(Ranker.ageInDays("not a date", today: now) == nil, "a malformed date has no age")
_ = today

// MARK: kinds
func kind(_ title: String, pubmed: [String] = [], journal: String? = nil, source: String? = nil,
          oa: String? = nil, abstract: String? = nil) -> PaperKind {
    var p = Paper(id: "K", title: title, date: "2026-10-01")
    p.pubmedTypes = pubmed; p.journal = journal; p.sourceType = source; p.openAlexType = oa; p.abstract = abstract
    return p.kind
}
check(kind("Anything", pubmed: ["Journal Article", "Case Reports"]) == .caseReport, "PubMed says case report")
check(kind("Anything", pubmed: ["Journal Article", "Review"]) == .review, "PubMed says review")
check(kind("Anything", pubmed: ["Congress"]) == .conferenceAbstract, "PubMed says congress")
check(kind("Anything", pubmed: ["Editorial"]) == .commentary, "PubMed says editorial")
check(kind("P-452: Erythromelalgia in pediatric type 1 diabetes") == .conferenceAbstract, "poster number in the title")
check(kind("IL-6: a key cytokine in chronic pain") == .research, "a cytokine name is not a poster number")
check(kind("Anything", journal: "Abstracts of the 2026 World Congress on Pain") == .conferenceAbstract, "venue named Abstracts")
check(kind("Anything", journal: "Proceedings of the National Academy of Sciences") == .research, "PNAS is a journal")
check(kind("Anything", source: "conference") == .conferenceAbstract, "OpenAlex source type conference")
check(kind("MR neurography of L3-L4 radiculitis: a case report") == .caseReport, "case report in the title")
check(kind("Peripatellar pain", abstract: "Rationale: We report a case of a 54-year-old man") == .caseReport, "case report in the abstract")
check(kind("Anything", oa: "review") == .review, "OpenAlex says review")
check(kind("Anything", source: "repository", oa: "preprint") == .preprint, "a preprint on a preprint server is a preprint")
check(kind("Anything", source: "journal", oa: "preprint") == .research, "typed preprint but published in a journal: a journal article")
check(kind("Brainstem circuit for cold-induced pain relief in mice") == .research, "an ordinary paper is research")

// MARK: kind weights (what the app's per-kind controls set)
func ranked(_ list: [Paper], _ s: FeedSettings) -> [String] {
    Ranker.rank(list, profileTexts: profile, settings: s, today: now).map(\.paper.id)
}
var caseRep = paper("CR", "Cortical responses to painful heat stimuli in volunteers")
caseRep.pubmedTypes = ["Case Reports"]
var poster = paper("PO", "Cortical responses to painful heat stimuli in volunteers")
poster.pubmedTypes = ["Congress"]
let ordinary = paper("OK", "Cortical responses to painful heat stimuli in volunteers", age: 20)
let defaults = FeedSettings()
check(ranked([caseRep, ordinary], defaults).first == "OK", "case report sinks by default")
check(ranked([poster, ordinary], defaults).first == "OK", "conference abstract sinks by default")
var keepCases = FeedSettings(); keepCases.setWeight(.normal, for: .caseReport)
check(ranked([caseRep, ordinary], keepCases).first == "CR", "case report keeps its place when set to normal")
var keepPosters = FeedSettings(); keepPosters.setWeight(.normal, for: .conferenceAbstract)
check(ranked([poster, ordinary], keepPosters).first == "PO", "conference abstract keeps its place when set to normal")
var boostCases = FeedSettings(); boostCases.setWeight(.boost, for: .caseReport)
check(ranked([ordinary, caseRep], boostCases).first == "CR", "a boosted kind rises")

// MARK: percentiles
check(Ranker.percentiles([10, 20, 30]) == [0, 0.5, 1], "percentiles of distinct values")
check(Ranker.percentiles([1, 1, 2]) == [0.25, 0.25, 1], "ties share their average rank")
check(Ranker.percentiles([5]) == [0.5], "one value is the middle")

// MARK: PubMed
let xml = """
<?xml version="1.0"?>
<PubmedArticleSet>
<PubmedArticle><MedlineCitation><PMID Version="1">111</PMID>
<Article><Journal><Title>J</Title></Journal>
<Abstract><AbstractText Label="BACKGROUND">Pain is <i>common</i>.</AbstractText><AbstractText Label="RESULTS">It hurts.</AbstractText></Abstract>
<PublicationTypeList><PublicationType UI="D016428">Journal Article</PublicationType><PublicationType UI="D016454">Review</PublicationType></PublicationTypeList>
</Article>
<CommentsCorrectionsList><CommentsCorrections RefType="Cites"><PMID Version="1">999</PMID></CommentsCorrections></CommentsCorrectionsList>
</MedlineCitation></PubmedArticle>
<PubmedArticle><MedlineCitation><PMID Version="1">222</PMID>
<Article><PublicationTypeList><PublicationType UI="D002363">Case Reports</PublicationType></PublicationTypeList></Article>
<OtherAbstract Type="Publisher" Language="spa"><AbstractText>Texto</AbstractText></OtherAbstract>
</MedlineCitation></PubmedArticle>
</PubmedArticleSet>
"""
let records = PubMedParser.parse(Data(xml.utf8))
check(records.map(\.pmid) == ["111", "222"], "PubMed: the article's PMID, not a cited one")
check(records.first?.abstract == "Background: Pain is common. Results: It hurts.", "PubMed: labelled sections, inline tags flattened")
check(records.first?.publicationTypes == ["Journal Article", "Review"], "PubMed: publication types")
check(records.last?.abstract == nil && records.last?.publicationTypes == ["Case Reports"], "PubMed: no abstract stays nil, translation ignored")

var withPMID = Paper(id: "E1", pmid: "111", title: "t", date: "2026-10-01")
var hasAbstract = Paper(id: "E2", pmid: "111", title: "t", abstract: "kept", date: "2026-10-01")
let enriched = Enrich.apply(records, to: [withPMID, hasAbstract, Paper(id: "E3", title: "t", date: "d")])
check(enriched[0].abstract == "Background: Pain is common. Results: It hurts." && enriched[0].abstractFromPubMed, "enrich fills a missing abstract")
check(enriched[1].abstract == "kept" && !enriched[1].abstractFromPubMed, "enrich never replaces an abstract")
check(enriched[0].pubmedTypes == ["Journal Article", "Review"] && enriched[0].kind == .review, "enrich attaches types, which set the kind")
check(enriched[2].pubmedTypes.isEmpty, "a paper with no PMID is left alone")
withPMID.pmid = nil; withPMID.doi = "10.1/x"; hasAbstract.doi = nil
check(Enrich.attach(pmids: ["10.1/x": "111"], to: [withPMID, hasAbstract]).map(\.pmid) == ["111", "111"], "attach gives a DOI-only paper its PMID")

// MARK: embeddings (a stand-in: "hurt" words point one way, "galaxy" words the other)
struct FakeEmbedder: TextEmbedder {
    func vector(for text: String) -> [Double]? {
        let t = text.lowercased()
        if t.contains("nociception") || t.contains("hurts") || t.contains("ache") { return [1, 0.1] }
        if t.contains("galaxy") || t.contains("dark matter") { return [0.1, 1] }
        return nil
    }
}
let synonymProfile = ["Nociception in the human brain", "Nociception and attention"]
let hurts = paper("H", "Why it hurts: ache in the cortex")      // no word in common with the profile
let stars = paper("S", "Dark matter and galaxy formation")
let lexicalOnly = Ranker.rank([stars, hurts], profileTexts: synonymProfile, today: now)
let withEmbedder = Ranker.rank([stars, hurts], profileTexts: synonymProfile, embedder: FakeEmbedder(), today: now)
check(withEmbedder.first?.paper.id == "H", "embeddings find a paper that shares meaning but no words")
check(withEmbedder.first!.similarity > lexicalOnly.first!.similarity || lexicalOnly.first!.similarity == 0.5,
      "embeddings separate papers the word counts could not")
let unreadable = paper("U", "Something the embedder cannot read")
check(Ranker.rank([unreadable, hurts], profileTexts: synonymProfile, embedder: FakeEmbedder(), today: now).count == 2,
      "a paper the embedder cannot read still gets ranked")


// MARK: settings file
let blank = try! FeedSettings.decode(Data("{}".utf8))
check(blank == FeedSettings(), "an empty file is the default settings")
check(blank.weight(for: .caseReport) == .lower && blank.weight(for: .research) == .normal, "defaults: case reports lowered, the rest normal")
let sparse = try! FeedSettings.decode(Data("""
{"orcid":"0000-0000-0000-0001","daysBack":7,"unknownFutureKey":[1,2,3],
 "followedJournals":[{"id":"S1","name":"Pain"}],"kindWeights":{"caseReport":"lowr","review":"boost"}}
""".utf8))
check(sparse.orcid == "0000-0000-0000-0001" && sparse.daysBack == 7, "keys present are read")
check(sparse.followedJournals == [Entity(id: "S1", name: "Pain")], "followed journals are read")
check(sparse.weight(for: .caseReport) == .normal && sparse.weight(for: .review) == .boost, "a mistyped weight means normal, a good one is kept")
check(sparse.useMyPublications && sparse.closeness == 0.5, "keys absent take their defaults")
let broken = try! FeedSettings.decode(Data(#"{"daysBack":"soon","recency":9,"closeness":-3,"followedTopics":"all"}"#.utf8))
check(broken.daysBack == 30 && broken.followedTopics.isEmpty, "a wrongly typed value falls back instead of failing the file")
check(broken.recency == 1 && broken.closeness == 0, "sliders are clamped to 0…1")
check((try? FeedSettings.decode(Data("not json".utf8))) == nil, "text that is not JSON throws, so it can be reported")
var roundTrip = FeedSettings()
roundTrip.orcid = "x"; roundTrip.followedKeywords = [KeywordRule(phrase: "pain", alsoRequire: ["EEG"], exclude: ["rat"])]
roundTrip.mutedAuthors = [Entity(id: "A9", name: "Z")]; roundTrip.setWeight(.hide, for: .preprint)
check((try? FeedSettings.decode(roundTrip.encoded())) == roundTrip, "settings survive a save and a load")

// MARK: from settings to seeds
var follow = FeedSettings()
follow.followedTopics = [Entity(id: "T1", name: "Pain")]
follow.followedJournals = [Entity(id: "S2", name: "Brain")]
follow.followedKeywords = [KeywordRule(phrase: "predictive coding")]
follow.trackedPapers = [Entity(id: "W77", name: "A paper")]
let planned = FeedBuilder.seeds(follow, myTopics: [Entity(id: "T1", name: "Pain"), Entity(id: "T3", name: "Touch")], myWorkIDs: ["W1", "W2"])
check(planned.count == 6, "own topics + own citations + four follows, the shared topic counted once")
check(planned.first { $0.seed == .topic(id: "T1", name: "Pain") }?.explicit == true, "a topic that is both followed and inferred counts as followed")
check(planned.first { $0.seed == .topic(id: "T3", name: "Touch") }?.explicit == false, "an inferred topic is not marked followed")
check(planned.contains { $0.seed.reason == "Cites: A paper" }, "a tracked paper becomes a citation seed with its own label")
var noPubs = follow; noPubs.useMyPublications = false
check(FeedBuilder.seeds(noPubs, myTopics: [Entity(id: "T3", name: "Touch")], myWorkIDs: ["W1"]).count == 4, "without publications only the follows remain")
check(Seed.institution(id: "I1", name: "x").filter(since: "d").hasPrefix("authorships.institutions.lineage:I1"), "institution filter")
check(Seed.funder(id: "F1", name: "x").filter(since: "d").hasPrefix("awards.funder_id:F1"), "funder filter")
let keywordFilter = Seed.keyword("a, b").filter(since: "d")
check(keywordFilter == "title_and_abstract.search:a  b,from_publication_date:d", "a comma in a keyword cannot end the filter early")

// MARK: filters
func ok(_ id: String, _ mutate: (inout Paper) -> Void = { _ in }) -> Paper {
    var p = paper(id, "Cortical responses to painful heat stimuli")
    mutate(&p)
    return p
}
func kept(_ list: [Paper], _ s: FeedSettings) -> [String] { FeedBuilder.keep(list, settings: s).map(\.id) }

var mute = FeedSettings()
mute.mutedJournals = [Entity(id: "S5", name: "J")]; mute.mutedAuthors = [Entity(id: "A5", name: "Au")]; mute.mutedTopics = [Entity(id: "T5", name: "Tp")]
mute.mutedKeywords = ["Rat"]
check(kept([ok("a") { $0.journalID = "S5" }, ok("b"), ], mute) == ["b"], "muted journal is dropped")
check(kept([ok("a") { $0.authorIDs = ["A5"] }, ok("b")], mute) == ["b"], "muted author is dropped")
check(kept([ok("a") { $0.topicIDs = ["T1", "T5"] }, ok("b")], mute) == ["b"], "muted topic is dropped")
check(kept([ok("a") { $0.abstract = "Experiments in a rat model" }, ok("b")], mute) == ["b"], "muted keyword is dropped, whatever its case")
var abstracts = FeedSettings(); abstracts.requireAbstract = true
check(kept([ok("a"), ok("b") { $0.abstract = "x" }], abstracts) == ["b"], "require abstract")
var open = FeedSettings(); open.openAccessOnly = true
check(kept([ok("a"), ok("b") { $0.isOpenAccess = true }], open) == ["b"], "open access only")
var english = FeedSettings(); english.languages = ["en"]
check(kept([ok("a") { $0.language = "fr" }, ok("b") { $0.language = "EN" }, ok("c")], english) == ["b", "c"], "language filter; unknown language passes")
var hideKind = FeedSettings(); hideKind.setWeight(.hide, for: .preprint)
check(kept([ok("a") { $0.openAlexType = "preprint" }, ok("b")], hideKind) == ["b"], "a hidden kind is dropped")
var fb = FeedSettings()
let seen = ok("seen")
fb.feedback.hide(seen)
check(kept([seen, ok("other")], fb) == ["other"], "a hidden paper never comes back")
fb.feedback.unhide(seen)
check(kept([seen], fb) == ["seen"], "unhide brings it back")

var rules = FeedSettings()
rules.followedKeywords = [KeywordRule(phrase: "attention", alsoRequire: ["pain"], exclude: ["deficit"])]
let reason = Seed.keyword("attention").reason
check(kept([ok("a") { $0.reasons = [reason]; $0.title = "Attention and pain" }], rules) == ["a"], "keyword rule satisfied")
check(kept([ok("a") { $0.reasons = [reason]; $0.title = "Attention deficit and pain" }], rules).isEmpty, "keyword exclude drops what only that keyword found")
check(kept([ok("a") { $0.reasons = [reason]; $0.title = "Attention in vision" }], rules).isEmpty, "keyword alsoRequire drops what only that keyword found")
check(kept([ok("a") { $0.reasons = [reason, "Topic: Pain"]; $0.title = "Attention deficit" }], rules) == ["a"], "a paper another seed found does not need to pass the keyword's rule")

// MARK: feedback teaches the profile
var learn = FeedSettings()
learn.useMyPublications = false
learn.feedback.save(ok("sv") { $0.title = "Nociception in the human brain"; $0.abstract = "pain" })
learn.feedback.save(ok("sv") { $0.title = "Nociception in the human brain" })
check(learn.feedback.saved.count == 1, "saving twice keeps one copy")
check(FeedBuilder.profileTexts(learn, own: [ok("mine")]).count == 1, "saved papers are the profile when publications are off")
learn.useMyPublications = true
check(FeedBuilder.profileTexts(learn, own: [ok("mine")]).count == 2, "own papers and saved papers together")

// MARK: the sliders and the follow bonus
var noRecency = FeedSettings(); noRecency.recency = 0
let newer = paper("N", "Dark matter halos in distant galaxy clusters", age: 1)
let older = paper("O2", "Dark matter halos in distant galaxy clusters", age: 25)
check(Ranker.rank([older, newer], profileTexts: profile, settings: noRecency, today: now).map(\.score).first
      == Ranker.rank([older, newer], profileTexts: profile, settings: noRecency, today: now).map(\.score).last,
      "recency 0 ignores age")
var followedP = paper("F1", "Dark matter halos in distant galaxy clusters"); followedP.followed = true
let plainP = paper("F2", "Dark matter halos in distant galaxy clusters")
check(Ranker.rank([plainP, followedP], profileTexts: profile, today: now).first?.paper.id == "F1", "something the user follows rises")
var nearFollow = FeedSettings(); nearFollow.closeness = 0
let r0 = Ranker.rank([pain, galaxy], profileTexts: profile, settings: nearFollow, today: now)
check(abs(r0[0].score - r0[1].score) < 0.001, "closeness 0 stops similarity from mattering")
let m1 = Merge.combine([followedP, plainP.withDOI("10.1/q"), ])
check(m1.count == 2, "merge keeps distinct papers apart")


// MARK: embedding cache
final class CountingEmbedder: TextEmbedder {
    var calls = 0
    func vector(for text: String) -> [Double]? { calls += 1; return text.isEmpty ? nil : [Double(text.count), 1, 0.5] }
}
let counting = CountingEmbedder()
let cache = CachingEmbedder(counting)
_ = cache.vector(for: "alpha"); _ = cache.vector(for: "alpha"); _ = cache.vector(for: "beta")
check(counting.calls == 2 && cache.hits == 1 && cache.misses == 2, "the same text is embedded once")
check(cache.vector(for: "") == nil, "an unreadable text is not cached")
let saved = cache.snapshot()!
let counting2 = CountingEmbedder()
let reloaded = CachingEmbedder(counting2, stored: saved)
check(reloaded.vector(for: "alpha") == cache.vector(for: "alpha") && counting2.calls == 0, "vectors survive a restart")
check(reloaded.count == 2, "reloaded cache has what was saved")
let trimmed = CachingEmbedder(CountingEmbedder(), stored: cache.snapshot(keeping: ["alpha"]))
check(trimmed.count == 1, "a snapshot can keep only the texts still in use")
check(CachingEmbedder.hash("abc") == CachingEmbedder.hash("abc") && CachingEmbedder.hash("abc") != CachingEmbedder.hash("abd"), "hash is stable and distinguishes texts")
let codedPaper = try! JSONDecoder().decode(Paper.self, from: JSONEncoder().encode(Paper(id: "W1", doi: "10.1/x", title: "T", date: "2026-01-01")))
check(codedPaper.doi == "10.1/x" && codedPaper.title == "T", "a paper survives the feed cache")


// MARK: history: new, seen, read
let day: TimeInterval = 86_400
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var hist = History()
let pa = ok("ha"), pb = ok("hb"), pc = ok("hc")
check(hist.status(of: pa.dedupeKey) == .new, "a paper never shown is new")
hist.markSeen(pa.dedupeKey, at: t0)
check(hist.status(of: pa.dedupeKey) == .seen, "a shown paper is seen")
hist.markSeen(pa.dedupeKey, at: t0.addingTimeInterval(day))
check(hist.states[pa.dedupeKey]?.seenCount == 2 && hist.states[pa.dedupeKey]?.firstSeen == t0, "seeing again counts, and keeps the first sighting")
hist.markOpened(pb, at: t0)
check(hist.status(of: pb.dedupeKey) == .read, "an opened paper is read, even if never scrolled past")
check(hist.read.first?.paper.title == pb.title, "read papers keep a snapshot for the Read list")
hist.markSeen(pb.dedupeKey, at: t0.addingTimeInterval(day))
check(hist.status(of: pb.dedupeKey) == .read, "seeing a read paper again does not make it unread")
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
check((try? dec.decode(History.self, from: enc.encode(hist))) == hist, "history survives a save and a load")

func rp(_ p: Paper, _ score: Double) -> RankedPaper { RankedPaper(paper: p, score: score, similarity: 0.5) }
let list = [rp(pa, 3), rp(pb, 2), rp(pc, 1)]
let settings7 = FeedSettings()
let arranged = Arranger.arrange(list, history: hist, settings: settings7, now: t0.addingTimeInterval(2 * day))
check(arranged.fresh.map(\.paper.id) == ["hc"], "unseen papers are new")
check(arranged.earlier.map(\.paper.id) == ["ha"], "seen papers go to earlier")
check(arranged.read.map(\.paper.id) == ["hb"], "read papers are set apart")
let later = Arranger.arrange(list, history: hist, settings: settings7, now: t0.addingTimeInterval(9 * day))
check(later.earlier.isEmpty && later.fresh.map(\.paper.id) == ["hc"], "a seen paper expires after seven days")
hist.markSeen(pa.dedupeKey, at: t0.addingTimeInterval(8 * day))
check(Arranger.arrange(list, history: hist, settings: settings7, now: t0.addingTimeInterval(9 * day)).earlier.isEmpty,
      "expiry counts from the first sighting, so scrolling back does not keep a card alive")
var longer = FeedSettings(); longer.seenExpiryDays = 14
check(Arranger.arrange(list, history: hist, settings: longer, now: t0.addingTimeInterval(9 * day)).earlier.map(\.paper.id) == ["ha"], "the expiry is a setting")
let ranking = Arranger.arrange([rp(pc, 1), rp(ok("hd"), 5), rp(ok("he"), 3)], history: History(), settings: settings7, now: t0)
check(ranking.fresh.map(\.paper.id) == ["hc", "hd", "he"], "arranging keeps the ranked order within a group")
hist.markSeen("old", at: t0.addingTimeInterval(-500 * day))
hist.prune(now: t0)
check(hist.states["old"] == nil && hist.states[pa.dedupeKey] != nil, "prune forgets only very old states")
let expirySettings = try! FeedSettings.decode(Data(#"{"seenExpiryDays":500,"showReadPapers":true}"#.utf8))
check(expirySettings.seenExpiryDays == 60 && expirySettings.showReadPapers, "history settings are read and clamped")

// MARK: covers
let coverPaper = ok("cv") { $0.topics = ["Pain Mechanisms and Treatments"] }
check(Cover.spec(for: coverPaper) == Cover.spec(for: coverPaper), "the same paper always gets the same cover")
let sameTopic = ok("cv2") { $0.topics = ["Pain Mechanisms and Treatments"]; $0.title = "Something else about pain" }
let otherTopic = ok("cv3") { $0.topics = ["Galaxy formation"]; $0.title = "Dark matter halos" }
check(Cover.spec(for: coverPaper).hueA == Cover.spec(for: sameTopic).hueA, "papers on one topic share a colour")
check(Cover.spec(for: coverPaper).hueA != Cover.spec(for: otherTopic).hueA, "different topics get different colours")
check(Cover.symbol(for: ok("s1") { $0.title = "Touch and haptic feedback" }) == "hand.point.up.left", "a symbol follows the subject")
check(Cover.symbol(for: ok("s2") { $0.title = "Ion channel gating in nociceptors" }) == "atom", "the more specific subject wins")
check(Cover.symbol(for: ok("s3") { $0.title = "Dark matter halos" }) == "doc.text.magnifyingglass", "an unknown subject gets the generic symbol")
check((0...1).contains(Cover.spec(for: coverPaper).hueA) && (0...1).contains(Cover.spec(for: coverPaper).hueB), "hues are valid")


// MARK: incremental refresh
let tNow = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed "now"
let baseSettings = FeedSettings()
func prev(fetched: Double = 1, full: Double = 1, with s: FeedSettings = baseSettings) -> PreviousFeed {
    PreviousFeed(papers: [], fetchedThrough: tNow.addingTimeInterval(-fetched * day),
                 fullBuildAt: tNow.addingTimeInterval(-full * day), builtWith: s.withoutFeedback)
}
check(Incremental.mode(previous: nil, settings: baseSettings, now: tNow) == .full(reason: "first build"), "no previous feed: full build")
check(Incremental.mode(previous: prev(), settings: baseSettings, now: tNow).isIncremental, "a recent feed on the same settings: incremental")
var changed = baseSettings; changed.followedKeywords = [KeywordRule(phrase: "x")]
check(Incremental.mode(previous: prev(), settings: changed, now: tNow) == .full(reason: "settings changed"), "changed follows: full build, the kept reasons would be wrong")
var onlyFeedback = baseSettings; onlyFeedback.feedback.hidden = ["doi:1"]
check(Incremental.mode(previous: prev(), settings: onlyFeedback, now: tNow).isIncremental, "hiding a paper does not force a full build")
check(!Incremental.mode(previous: prev(full: 4), settings: baseSettings, now: tNow).isIncremental, "a full build is repeated after three days")
check(Incremental.mode(previous: prev(full: 2.9), settings: baseSettings, now: tNow).isIncremental, "and not before")
check(!Incremental.mode(previous: prev(fetched: 31), settings: baseSettings, now: tNow).isIncremental, "away longer than the look-back: full build")
check(Incremental.mode(previous: prev(fetched: 1, with: week), settings: baseSettings, now: tNow) == .full(reason: "settings changed"), "a different look-back is a different feed: full build")
let fetchedOneDayAgo = Incremental.mode(previous: prev(fetched: 1), settings: baseSettings, now: tNow)
check(fetchedOneDayAgo == .incremental(since: Ranker.dayString(tNow.addingTimeInterval(-4 * day))), "starts three days before the last fetch, to catch late records")
var week = baseSettings; week.daysBack = 7
check(Incremental.mode(previous: prev(fetched: 6, with: week), settings: week, now: tNow) == .incremental(since: Ranker.dayString(tNow.addingTimeInterval(-7 * day))),
      "never reaches back past the look-back window")

let winStart = Ranker.dayString(tNow.addingTimeInterval(-30 * day))
func dated(_ id: String, daysAgo: Double, doi: String? = nil) -> Paper {
    // Dated from the fixed test clock, like the window, not from the real one.
    var p = Paper(id: id, title: "T \(id)", date: Ranker.dayString(tNow.addingTimeInterval(-daysAgo * day)))
    p.doi = doi
    return p
}
let oldKept = dated("old", daysAgo: 20), tooOld = dated("ancient", daysAgo: 45)
let mergedFeed = Incremental.merge(previous: [oldKept, tooOld], fresh: [dated("new", daysAgo: 1)], windowStart: winStart)
check(Set(mergedFeed.map(\.id)) == ["old", "new"], "papers older than the look-back age out, the rest are kept")
var prevCopy = dated("same", daysAgo: 5, doi: "10.1/s"); prevCopy.reasons = ["Topic: A"]
var freshCopy = dated("same2", daysAgo: 5, doi: "10.1/s"); freshCopy.reasons = ["Journal: B"]; freshCopy.abstract = "now has one"
let dup = Incremental.merge(previous: [prevCopy], fresh: [freshCopy], windowStart: winStart)
check(dup.count == 1 && dup[0].abstract == "now has one", "a paper seen again is one paper, with the newer data")
check(Set(dup[0].reasons) == ["Topic: A", "Journal: B"], "and keeps every reason it was found for")
check(Incremental.merge(previous: [oldKept], fresh: [], windowStart: winStart).map(\.id) == ["old"], "nothing new still keeps the old feed")


var enrichedBefore = dated("p1", daysAgo: 4, doi: "10.1/carry")
enrichedBefore.pmid = "777"; enrichedBefore.pubmedTypes = ["Journal Article", "Review"]
enrichedBefore.abstract = "from pubmed"; enrichedBefore.abstractFromPubMed = true
let refetched = dated("p1b", daysAgo: 4, doi: "10.1/carry")
let carried = Incremental.carryOver(from: [enrichedBefore], into: [refetched, dated("other", daysAgo: 1, doi: "10.1/other")])
check(carried[0].pubmedTypes == ["Journal Article", "Review"] && carried[0].pmid == "777", "PubMed's types and PMID are carried to the fresh copy")
check(carried[0].abstract == "from pubmed" && carried[0].abstractFromPubMed, "so is an abstract PubMed supplied")
check(carried[1].pubmedTypes.isEmpty && carried[1].abstract == nil, "a paper not seen before is left alone")
var withOwn = refetched; withOwn.abstract = "openalex abstract"
check(Incremental.carryOver(from: [enrichedBefore], into: [withOwn])[0].abstract == "openalex abstract", "an abstract the fresh copy already has is kept")
check(Incremental.carryOver(from: [], into: [refetched]) == [refetched], "with nothing before, nothing changes")


var checkedBefore = dated("nf", daysAgo: 2, doi: "10.1/notthere"); checkedBefore.notInPubMed = true
check(Incremental.carryOver(from: [checkedBefore], into: [dated("nf2", daysAgo: 2, doi: "10.1/notthere")])[0].notInPubMed == true,
      "a paper already found to be absent from PubMed is not looked up again")
check(try! JSONDecoder().decode(Paper.self, from: Data(#"{"id":"W1","title":"T","date":"2026-01-01","authors":[],"authorIDs":[],"citedBy":0,"topics":[],"topicIDs":[],"isOpenAccess":false,"isRepository":false,"pubmedTypes":[],"abstractFromPubMed":false,"reasons":[],"citesYou":false,"followed":false}"#.utf8)).notInPubMed == nil,
      "a cache written before the field existed still loads")


// MARK: the one-sentence summary
check(Summary.sentence(from: nil) == nil && Summary.sentence(from: "  ") == nil, "no abstract, no summary")
check(Summary.strippingHeading("Background And Aims: Chronic pain is common.") == "Chronic pain is common.", "a labelled heading is removed")
check(Summary.strippingHeading("Abstract Application of cold relieves pain.") == "Application of cold relieves pain.", "a heading glued to the sentence is removed")
check(Summary.strippingHeading("Results: Pain fell by half.") == "Pain fell by half.", "Results: is removed")
check(Summary.strippingHeading("Resting-state EEG captures sensitisation.") == "Resting-state EEG captures sensitisation.", "an ordinary sentence is left alone")
let abstract1 = "Chronic pain affects a quarter of adults worldwide and is poorly treated. We aimed to test whether cold relieves pain in mice. We found that a brainstem enkephalin circuit mediates cold-induced analgesia in mice. These data open new routes to treatment."
check(Summary.sentence(from: abstract1) == "We found that a brainstem enkephalin circuit mediates cold-induced analgesia in mice.", "the sentence with the finding wins over background and intent")
let labelledAbstract = "BACKGROUND: Postoperative pain is common and costly for patients. METHODS: We recruited 200 adults. RESULTS: Pain scores were significantly lower in the treated group. CONCLUSION: Treatment improved recovery."
check(Summary.sentence(from: labelledAbstract)?.hasPrefix("Pain scores were significantly lower") == true || Summary.sentence(from: labelledAbstract)?.hasPrefix("Treatment improved") == true,
      "labels are stripped and a result or conclusion is chosen")
check(Summary.sentence(from: "Pain scores were significantly lower in the treated group of adults.") == "Pain scores were significantly lower in the treated group of adults.", "a one-sentence abstract is returned whole")
let noFinding = "Pain is common among adults in every country. Treatment options remain limited for many of those patients. Access to care varies widely between regions."
check(Summary.sentence(from: noFinding) == "Access to care varies widely between regions.", "with no finding, the last sentence is chosen")
let long = "We found that " + String(repeating: "a very long clause about pain ", count: 20) + "mattered."
let clipped = Summary.sentence(from: long, maxLength: 80)!
check(clipped.count <= 81 && clipped.hasSuffix("…") && !clipped.contains("  "), "a long sentence is clipped on a word boundary")
check(Summary.clip("short one", to: 80) == "short one", "a short sentence is not clipped")
check(Summary.sentence(from: "Fig. 2 shows e.g. the mean of 3.5 units. We found that cold relieved pain significantly in treated mice.")?.hasPrefix("We found") == true, "abbreviations and decimals do not split a sentence")


// MARK: byline
check(Byline.initials("Valéry Legrain") == "VL", "initials: first and last name")
check(Byline.initials("Ludwig van der Berg") == "LB", "initials: particles are skipped by taking the last word")
check(Byline.initials("Jean-Pierre Dupont") == "JD", "initials: a hyphenated first name gives one letter")
check(Byline.initials("Madonna") == "MA", "initials: a single name gives two letters")
check(Byline.initials("") == "?", "initials: no name, no letters")
check(Byline.hue(for: "Valéry Legrain") == Byline.hue(for: "valéry legrain"), "the colour does not depend on case")
check(Byline.hue(for: "Valéry Legrain") != Byline.hue(for: "André Mouraux"), "two people get different colours")
let bylined = ok("by1") { $0.authors = ["Ada First", "Mid Author", "Zoe Last"]; $0.firstInstitution = "Ghent University"; $0.lastInstitution = "UCLouvain" }
check(Byline.people(of: bylined, choice: .last).first?.name == "Zoe Last" && Byline.people(of: bylined, choice: .last).first?.institution == "UCLouvain", "last author leads with their own institution")
check(Byline.people(of: bylined, choice: .first).first?.name == "Ada First" && Byline.people(of: bylined, choice: .first).first?.institution == "Ghent University", "first author leads with their own institution")
check(Byline.people(of: ok("by2") { $0.authors = [] }, choice: .last).isEmpty, "a paper with no authors has no byline")
let both = Byline.people(of: bylined, choice: .both)
check(both.map(\.name) == ["Ada First", "Zoe Last"] && both.map(\.index) == [0, 2], "both: the first author, then the last, with their places in the list")
check(Byline.places(both) == "Ghent University · UCLouvain", "both: each person's institution, once")
let sameLab = ok("by4") { $0.authors = ["A One", "B Two"]; $0.firstInstitution = "UCLouvain"; $0.lastInstitution = "UCLouvain" }
check(Byline.places(Byline.people(of: sameLab, choice: .both)) == "UCLouvain", "both: a shared institution is named once")
check(Byline.people(of: ok("by5") { $0.authors = ["Solo Author"] }, choice: .both).count == 1, "both: a single author is shown once")
check(Cover.spec(for: ok("j1") { $0.journal = "Pain" }, byJournal: true).hueA == Cover.spec(for: ok("j2") { $0.journal = "PAIN"; $0.topics = ["Other"] }, byJournal: true).hueA, "one journal, one colour, whatever the topic")
check(Cover.spec(for: ok("j3") { $0.journal = "Pain" }, byJournal: true).hueA != Cover.spec(for: ok("j4") { $0.journal = "Nature" }, byJournal: true).hueA, "two journals, two colours")
check(Cover.spec(for: ok("j5") { $0.journal = nil }, byJournal: true) == Cover.spec(for: ok("j5") { $0.journal = nil }), "no journal: the topic colour")

// MARK: takeaway
let abstractA = "Background: Chronic pain is common and costly. We aimed to test whether cold relieves it. Cold significantly reduced pain in treated mice. The effect was mediated by TRPM8 channels. Further work is needed."
let taken = Summary.takeaway(from: abstractA)
check(taken == "Cold significantly reduced pain in treated mice. The effect was mediated by TRPM8 channels.", "takeaway: two result sentences, in the abstract's order, no background or aims")
check(taken?.hasSuffix("…") == false, "takeaway: a whole sentence is never cut off")
let longOne = "We found that " + String(repeating: "a very long clause about the experiment, ", count: 9) + "was significant."
check(Summary.takeaway(from: longOne + " Cold reduced pain significantly in treated mice.") == "Cold reduced pain significantly in treated mice.", "takeaway: a short result beats a rambling one")
check(Summary.takeaway(from: nil) == nil && Summary.takeaway(from: "Too short.") == nil, "takeaway: nothing to say, nothing returned")
check((Summary.takeaway(from: "Cold reduced pain significantly in treated mice. Heat increased it significantly in the same animals.") ?? "").count <= 300, "takeaway: stays within its budget")

let withInstitution = ok("by3") { $0.firstInstitution = "X" }
let withoutInstitution = ok("by3")
check(Merge.combine([withoutInstitution, withInstitution]).first?.firstInstitution == "X", "an institution one copy lacks is filled from the other")
let staleCache = PreviousFeed(papers: [ok("old")], fetchedThrough: tNow.addingTimeInterval(-day), fullBuildAt: tNow.addingTimeInterval(-day), builtWith: baseSettings.withoutFeedback)
check(!Incremental.mode(previous: staleCache, settings: baseSettings, now: tNow).isIncremental, "papers cached without institutions are rebuilt once")
var freshCache = staleCache
freshCache.papers = [ok("new") { $0.lastInstitution = "UCLouvain" }]
check(Incremental.mode(previous: freshCache, settings: baseSettings, now: tNow).isIncremental, "and an up-to-date cache is not")

let wordy = "The study found that cold reduced pain.\n\nIt also showed that heat did not.\n\nA third sentence is not wanted. A fourth neither."
check(Summary.limited(wordy) == "The study found that cold reduced pain. It also showed that heat did not.", "limited: two sentences, one paragraph")
check(Summary.limited("   ") == nil, "limited: nothing in, nothing out")
check(Summary.limited(String(repeating: "word ", count: 120) + "end.", maxLength: 80)?.hasSuffix("…") == true, "limited: one endless sentence is clipped, not passed on")

// MARK: why a post is in the feed
func why(_ reasons: [String], followed: Bool = true) -> Why? { Why.main(for: ok("why") { $0.reasons = reasons; $0.followed = followed }) }
check(why(["Topic: Pain", "Cites your work", "Journal: Pain"])?.text == "Cites your work", "why: a citation of your work beats everything")
check(why(["Topic: Pain", "Author: Ada First"])?.text == "Author you follow: Ada First", "why: a followed author beats a topic")
check(why(["Journal: Pain", "Topic: Pain"])?.text == "From a journal you follow", "why: a followed journal beats a topic")
check(why(["Topic: Pain", "Cites: My tracked paper"])?.text == "Cites a paper you track: My tracked paper", "why: a tracked paper's citation comes next after your own work")
check(why(["Topic: Pain"], followed: true)?.text == "Topic you follow: Pain", "why: a followed topic")
check(why(["Topic: Pain"], followed: false)?.text == "Topic from your own papers: Pain", "why: an inferred topic says so")
check(why(["Topic: Pain", "Journal: Pain", "Author: X"])?.others == 2, "why: counts the other reasons")
check(why([]) == nil, "why: no reason, no line")
check(why(["Cites your work"])?.isCitation == true && why(["Topic: Pain"])?.isCitation == false, "why: only citations are marked as such")
let everySeed: [Seed] = [.topic(id: "T1", name: "Pain"), .journal(id: "S1", name: "Pain"), .author(id: "A1", name: "Ada"),
                         .institution(id: "I1", name: "UCLouvain"), .funder(id: "F1", name: "FNRS"), .keyword("tactile"),
                         .cites(workIDs: ["W1"], label: "Cites your work"), .cites(workIDs: ["W2"], label: "Cites: A tracked paper")]
check(everySeed.allSatisfy { seed in
    let w = why([seed.reason])
    return w != nil && w?.symbol != Why.fallbackSymbol
}, "why: every kind of seed is understood, so renaming a reason prefix fails here")

// MARK: journal impact
var impactOn = FeedSettings(); impactOn.impactWeight = 1
let nature = ok("hi") { $0.journalImpact = 24; $0.date = "2026-10-01" }
let obscure = ok("lo") { $0.journalImpact = 0.4; $0.date = "2026-10-01" }
let unknownJournal = ok("none") { $0.journalImpact = nil; $0.date = "2026-10-01" }
check(Ranker.rank([obscure, nature], profileTexts: profile, settings: impactOn, today: now).first?.paper.id == "hi", "impact on: a high-impact journal ranks above a low one")
let withoutImpact = Ranker.rank([obscure, nature], profileTexts: profile, today: now)
check(withoutImpact.first?.score == withoutImpact.last?.score, "impact off (the default): the journal changes nothing")
check(Ranker.impactBoost(nil, weight: 1) == 0 && Ranker.impactBoost(24, weight: 0) == 0, "impact: no figure or no weight, no effect")
check(Ranker.impactBoost(0.4, weight: 1) < 0 && Ranker.impactBoost(24, weight: 1) > 0, "impact: below about two is pushed down, above it up")
check(Ranker.impactBoost(100, weight: 1) == Ranker.impactBoost(24, weight: 1), "impact: capped, so one journal cannot dominate")
check(Ranker.impactBoost(5, weight: 0.5) == Ranker.impactBoost(5, weight: 1) / 2, "impact: the slider scales it")
let neutral = Ranker.rank([unknownJournal], profileTexts: profile, settings: impactOn, today: now).first?.score
check(neutral == Ranker.rank([unknownJournal], profileTexts: profile, today: now).first?.score, "impact: an unknown journal is neither rewarded nor penalised")
var slid = baseSettings; slid.recency = 0.9; slid.closeness = 0.1; slid.impactWeight = 1
check(Incremental.mode(previous: prev(), settings: slid, now: tNow).isIncremental, "moving a ranking slider re-ranks incrementally, without a full rebuild")
check(slid.withoutFeedback != baseSettings.withoutFeedback && slid.forFetching == baseSettings.forFetching, "a ranking slider is a settings change, but not a fetching one")
check(try FeedSettings.decode(Data("{\"impactWeight\": 7}".utf8)).impactWeight == 1, "impact weight is clamped when read")
check(try FeedSettings.decode(Data("{}".utf8)).impactWeight == 0, "impact weight is off in an older settings file")

print(failures == 0 ? "\nAll passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
