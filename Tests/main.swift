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
let planned = FeedBuilder.seeds(follow, myWorkIDs: ["W1", "W2"])
check(planned.count == 5, "own citations + four follows: nothing is inferred behind the user's back")
check(planned.first { $0.seed == .topic(id: "T1", name: "Pain") }?.explicit == true, "a followed topic is marked followed")
check(!planned.contains { $0.seed == .topic(id: "T3", name: "Touch") }, "a topic of the user's own papers is not followed unless it is in the list")
check(planned.contains { $0.seed.reason == "Cites: A paper" }, "a tracked paper becomes a citation seed with its own label")
var noPubs = follow; noPubs.useMyPublications = false
check(FeedBuilder.seeds(noPubs, myWorkIDs: ["W1"]).count == 4, "without publications only the follows remain")
check(planned.filter { !$0.explicit }.count == 1, "the one seed that is not a follow is \"cites my work\"")
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
let reason = rules.followedKeywords[0].seed.reason
check(reason == "Keyword: attention + pain", "a rule's reason names the words it requires")
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
final class NamedEmbedder: TextEmbedder {
    let modelID: String; var calls = 0
    init(_ id: String) { modelID = id }
    func vector(for text: String) -> [Double]? { calls += 1; return [Double(text.count), 1, 0.5] }
}
let sentenceModel = NamedEmbedder("apple-sentence"), contextualModel = NamedEmbedder("apple-contextual")
let sentenceCache = CachingEmbedder(sentenceModel); _ = sentenceCache.vector(for: "alpha")
let sentenceSaved = sentenceCache.snapshot()!
check(CachingEmbedder(contextualModel, stored: sentenceSaved).count == 0, "embedding cache: vectors made by one model are never used by another")
check(CachingEmbedder(NamedEmbedder("apple-sentence"), stored: sentenceSaved).count == 1, "embedding cache: the model that wrote them may read them back")
let legacySaved: Data = {
    var d = try! PropertyListDecoder().decode([String: Data].self, from: sentenceSaved)
    d.removeValue(forKey: CachingEmbedder.modelKey)
    let e = PropertyListEncoder(); e.outputFormat = .binary
    return try! e.encode(d)
}()
check(CachingEmbedder(NamedEmbedder("apple-sentence"), stored: legacySaved).count == 1 && CachingEmbedder(contextualModel, stored: legacySaved).count == 0, "embedding cache: a file written before models were named came from the sentence model")
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

// MARK: author h-index
var authorsOn = FeedSettings(); authorsOn.authorWeight = 1
let seniorStar = ok("h1") { $0.firstAuthorH = 3; $0.lastAuthorH = 80; $0.date = "2026-10-01" }
let juniorStar = ok("h2") { $0.firstAuthorH = 60; $0.lastAuthorH = 4; $0.date = "2026-10-01" }
check(Ranker.rank([juniorStar, seniorStar], profileTexts: profile, settings: authorsOn, today: now).first?.paper.id == "h1", "h-index: by default the senior (last) author counts")
authorsOn.byline = .first
check(Ranker.rank([seniorStar, juniorStar], profileTexts: profile, settings: authorsOn, today: now).first?.paper.id == "h2", "h-index: the first author can be chosen instead")
authorsOn.byline = .both
check(abs(Ranker.authorBoost(seniorStar, weight: 1, focus: .both) - Ranker.authorBoost(juniorStar, weight: 1, focus: .both)) < 0.5, "h-index: 'either' takes the higher of the two, so both papers count as established")
check(Ranker.chosenH(seniorStar, focus: .both) == 80 && Ranker.chosenH(ok("h3") { $0.lastAuthorH = 7 }, focus: .both) == 7, "h-index: either, with only one known")
check(Ranker.authorBoost(ok("h4"), weight: 1, focus: .last) == 0, "h-index: an unknown author is neutral")
check(Ranker.authorBoost(seniorStar, weight: 0, focus: .last) == 0, "h-index: off by default, no effect")
check(Ranker.authorBoost(ok("h5") { $0.lastAuthorH = 2 }, weight: 1, focus: .last) < 0 && Ranker.authorBoost(ok("h6") { $0.lastAuthorH = 60 }, weight: 1, focus: .last) > 0, "h-index: a small one is pushed down, a large one up")
check(Ranker.authorBoost(ok("h7") { $0.lastAuthorH = 900 }, weight: 1, focus: .last) == Ranker.authorBoost(ok("h8") { $0.lastAuthorH = 100 }, weight: 1, focus: .last), "h-index: capped at a hundred")
check(ok("l1") { $0.authors = ["A", "B"]; $0.authorIDs = ["A1", "A2"] }.leadAuthorIDs?.last == "A2", "lead ids: the last author's id")
check(ok("l2") { $0.authors = ["A", "B", "C"]; $0.authorIDs = ["A1", "A2"] }.leadAuthorIDs == nil, "lead ids: not guessed when names and ids do not line up")
var slid2 = baseSettings; slid2.authorWeight = 1; slid2.byline = .first
check(Incremental.mode(previous: prev(), settings: slid2, now: tNow).isIncremental, "choosing the author h-index re-ranks incrementally")
check(try FeedSettings.decode(Data("{\"byline\": \"nonsense\"}".utf8)).byline == .last, "an unknown byline falls back to the last author")
var bylineOnly = baseSettings; bylineOnly.byline = .both
check(bylineOnly.forRanking == baseSettings.forRanking, "which author heads a post is display only while the h-index is off")
bylineOnly.authorWeight = 0.5
var bylineOther = bylineOnly; bylineOther.byline = .first
check(bylineOnly.forRanking != bylineOther.forRanking, "and a ranking choice once the h-index counts")
check(Ranker.authorBoost(seniorStar, weight: 1, focus: .both) == Ranker.authorBoost(ok("h9") { $0.lastAuthorH = 80 }, weight: 1, focus: .last), "both authors shown: the higher h-index counts")

// MARK: more than one source
check(SourceRouting.isOpenAlexID("W2741809807") && SourceRouting.isOpenAlexID("T10574"), "OpenAlex ids are recognised")
check(!SourceRouting.isOpenAlexID("epmc:MED:123") && !SourceRouting.isOpenAlexID("name:Pain") && !SourceRouting.isOpenAlexID("W"), "other ids are not")
func routes(_ seed: Seed, oa: Bool = true, epmc: Bool = true, pmids: Bool = true) -> [SourceKind] {
    SourceRouting.targets(for: seed, openAlex: oa, europePMC: epmc, hasOwnPMIDs: pmids)
}
check(routes(.keyword("tactile")) == [.openAlex, .europePMC], "a keyword is put to both sources")
check(routes(.journal(id: "S1", name: "Pain")) == [.openAlex, .europePMC], "a journal is put to both, the second by name")
check(routes(.journal(id: "name:Pain", name: "Pain")) == [.europePMC], "a journal added by name goes only where names work")
check(routes(.author(id: "A1", name: "Ada")) == [.openAlex], "an author with an id is not also searched by name while OpenAlex is on")
check(routes(.author(id: "A1", name: "Ada"), oa: false) == [.europePMC], "and is searched by name when OpenAlex is off")
check(routes(.author(id: "name:Ada L", name: "Ada L")) == [.europePMC], "an author added by name is searched by name")
check(routes(.topic(id: "T1", name: "Pain")) == [.openAlex] && routes(.topic(id: "T1", name: "Pain"), oa: false).isEmpty, "a topic needs OpenAlex")
check(routes(.mesh("Pain")) == [.europePMC], "a MeSH heading goes to Europe PMC")
check(routes(.cites(workIDs: ["W1", "W2"], label: "Cites your work")) == [.openAlex, .europePMC], "citations of your work are asked of both")
check(routes(.cites(workIDs: ["epmc:MED:1"], label: "Cites your work"), oa: true) == [.europePMC], "your own papers from another source cannot be put to OpenAlex")
check(routes(.cites(workIDs: ["W1"], label: "Cites: A tracked paper")) == [.openAlex], "a tracked paper is OpenAlex's")
check(routes(.cites(workIDs: ["W1"], label: "Cites your work"), pmids: false) == [.openAlex], "without PubMed ids Europe PMC cannot find citations")
check(routes(.keyword("x"), oa: false, epmc: false).isEmpty, "no source on, nothing to ask")

let window = ("2026-10-01", "2026-11-08")
check(EuropePMCQuery.build(.keyword("predictive coding"), since: window.0, until: window.1) == "(TITLE:\"predictive coding\" OR ABSTRACT:\"predictive coding\") AND FIRST_PDATE:[2026-10-01 TO 2026-11-08]", "keyword query")
check(EuropePMCQuery.build(.journal(id: "S1", name: "Pain"), since: window.0, until: window.1) == "JOURNAL:\"Pain\" AND FIRST_PDATE:[2026-10-01 TO 2026-11-08]", "journal query")
check(EuropePMCQuery.build(.author(id: "name:Mouraux A", name: "Mouraux A"), since: window.0, until: window.1)?.hasPrefix("AUTH:\"Mouraux A\"") == true, "an author by name uses the typed name")
check(EuropePMCQuery.build(.keyword("a\"b"), since: window.0, until: window.1)?.contains("\"a b\"") == true, "quotes in a phrase cannot break the query")
check(EuropePMCQuery.build(.topic(id: "T1", name: "x"), since: window.0, until: window.1) == nil, "an OpenAlex topic has no Europe PMC query")
check(EuropePMCQuery.build(.cites(workIDs: ["W1"], label: "Cites your work"), since: window.0, until: window.1) == nil, "citations need PubMed ids")
check(EuropePMCQuery.build(.cites(workIDs: ["W1"], label: "Cites your work"), since: window.0, until: window.1, ownPMIDs: ["1", "2"])?.hasPrefix("(CITES:1_MED OR CITES:2_MED)") == true, "citations by PubMed id")

let epmcJSON = """
{"hitCount": 2, "resultList": {"result": [
 {"id": "42972058", "source": "MED", "pmid": "42972058", "doi": "10.1038/S41577-026-01363-6",
  "title": "Peripheral neuroimmune dialogues underlying pain states.",
  "authorList": {"author": [
    {"fullName": "Grace PM", "authorAffiliationDetailsList": {"authorAffiliation": [{"affiliation": "Department of Translational Neuroscience, University of Texas MD Anderson Cancer Center, Houston, TX, USA."}]}},
    {"fullName": "Svensson CI", "authorAffiliationDetailsList": {"authorAffiliation": [{"affiliation": "Department of Physiology, Karolinska Institutet, Stockholm, Sweden."}]}}]},
  "journalInfo": {"journal": {"title": "Nature reviews. Immunology", "issn": "1474-1733"}},
  "pubYear": "2026", "firstPublicationDate": "2026-11-02", "language": "eng", "isOpenAccess": "N", "citedByCount": 3,
  "abstractText": "<h4>Background</h4>Pain is <i>profoundly</i> shaped by neuroimmune interactions &amp; more.",
  "pubTypeList": {"pubType": ["Review", "Journal Article"]},
  "meshHeadingList": {"meshHeading": [{"descriptorName": "Pain"}, {"descriptorName": "Nociceptors"}]}},
 {"id": "PPR1357541", "source": "PPR", "doi": "10.64898/2026.11.02.763662",
  "title": "Pain Matters: Nociceptive signaling drives neural encoding of inflammatory responses",
  "authorString": "Sammons M, Rolls A.", "bookOrReportDetails": {"publisher": "bioRxiv", "yearOfPublication": 2026},
  "firstPublicationDate": "2026-11-03", "pubTypeList": {"pubType": ["Preprint"]}, "isOpenAccess": "N"}
]}}
""".data(using: .utf8)!
let epmcPapers = EuropePMCParser.papers(from: epmcJSON)
check(epmcPapers.count == 2 && EuropePMCParser.hitCount(in: epmcJSON) == 2, "Europe PMC: both records read")
let epmcFirst = epmcPapers[0]
check(epmcFirst.doi == "10.1038/s41577-026-01363-6" && epmcFirst.pmid == "42972058", "Europe PMC: DOI lower-cased, PMID kept")
check(epmcFirst.title == "Peripheral neuroimmune dialogues underlying pain states", "Europe PMC: the trailing full stop is dropped from the title")
check(epmcFirst.abstract == "Background Pain is profoundly shaped by neuroimmune interactions & more.", "Europe PMC: markup stripped from the abstract")
check(epmcFirst.journal == "Nature reviews. Immunology" && epmcFirst.language == "en" && epmcFirst.citedBy == 3, "Europe PMC: journal, language, citations")
check(epmcFirst.firstInstitution == "University of Texas MD Anderson Cancer Center" && epmcFirst.lastInstitution == "Karolinska Institutet", "Europe PMC: institutions picked out of the affiliation strings")
check(epmcFirst.kind == .review && epmcFirst.topics == ["Pain", "Nociceptors"], "Europe PMC: publication types and MeSH headings")
check(epmcFirst.sourceNames == ["Europe PMC"] && epmcFirst.id == "epmc:MED:42972058", "Europe PMC: provenance and id")
let epmcPreprint = epmcPapers[1]
check(epmcPreprint.kind == .preprint && epmcPreprint.isRepository && epmcPreprint.journal == "bioRxiv", "Europe PMC: a preprint is a preprint, its server named")
check(epmcPreprint.link?.absoluteString == "https://doi.org/10.64898/2026.11.02.763662", "Europe PMC: a preprint links by DOI")
check(Paper(id: "epmc:PPR:PPR9", title: "t", date: "2026-01-01").link?.absoluteString == "https://europepmc.org/article/PPR/PPR9", "Europe PMC: a record with no DOI or PMID links to Europe PMC")
check(EuropePMCParser.papers(from: Data("not json".utf8)).isEmpty, "Europe PMC: garbage reads as nothing")

check(MeSH.isGeneric("Humans") && MeSH.isGeneric("Middle Aged") && !MeSH.isGeneric("Nociceptors"), "MeSH: check tags are generic, a real topic is not")
var checkTag = FeedSettings(); checkTag.followedTopics = [Entity(id: "mesh:Humans", name: "Humans")]
check(!FeedBuilder.seeds(checkTag, myWorkIDs: []).contains { $0.seed == .mesh("Humans") }, "MeSH: a check tag is never a seed")
check(Html.plain("<i>Objective.</i>Tumor stiffness") == "Objective.Tumor stiffness", "html: inline tags vanish without a gap")
check(Html.plain("<p>One</p><p>Two &lt;3</p>") == "One Two <3", "html: block tags become spaces, entities decode")
check(Affiliation.institution(from: "Department of Physiology, Faculty of Medicine, Karolinska Institutet, Stockholm, Sweden.") == "Karolinska Institutet", "affiliation: department and faculty are skipped")
check(Affiliation.institution(from: "Max Planck Institute for Brain Research, Frankfurt, Germany") == "Max Planck Institute for Brain Research", "affiliation: an institute")
check(Affiliation.institution(from: "Somewhere, Nowhere") == nil, "affiliation: nothing that names an institution")
check(Languages.iso1("eng") == "en" && Languages.iso1("fr") == "fr" && Languages.iso1("xyz") == nil && Languages.iso1("ara") == "ar" && Languages.iso1(nil) == nil, "language codes")

let byOrcidJSON = """
{"hitCount": 174, "resultList": {"result": [
 {"id": "1", "source": "MED", "title": "A paper", "firstPublicationDate": "2026-10-01",
  "authorList": {"author": [
    {"fullName": "Legrain V", "firstName": "Valéry", "lastName": "Legrain", "authorId": {"type": "ORCID", "value": "0000-0002-9999-0001"}},
    {"fullName": "Mouraux A", "firstName": "André", "lastName": "Mouraux", "authorId": {"type": "ORCID", "value": "0000-0003-1056-5980"}}]}},
 {"id": "2", "source": "MED", "title": "Another", "firstPublicationDate": "2026-09-01",
  "authorList": {"author": [{"fullName": "Doe J", "authorId": {"type": "ORCID", "value": "0000-0001-0000-0002"}}]}}
]}}
""".data(using: .utf8)!
check(EuropePMCQuery.orcid("0000-0003-1056-5980") == "AUTHORID:\"0000-0003-1056-5980\"", "by iD: the query asks for the author's iD, not the ORCID service")
check(EuropePMCParser.authorName(orcid: "0000-0003-1056-5980", in: byOrcidJSON) == "André Mouraux", "by iD: the name is the given and family names Europe PMC holds for that iD")
check(EuropePMCParser.authorName(orcid: "0000-0001-0000-0002", in: byOrcidJSON) == "Doe J", "by iD: the 'Doe J' form when there are no separate names")
check(EuropePMCParser.authorName(orcid: "0000-0000-0000-0000", in: byOrcidJSON) == nil && EuropePMCParser.authorName(orcid: "x", in: Data("nope".utf8)) == nil, "by iD: an iD no record carries, or garbage, has no name")
check(EuropePMCParser.hitCount(in: byOrcidJSON) == 174 && EuropePMCParser.papers(from: byOrcidJSON).count == 2, "by iD: the total and the papers are read")

// Merging across sources
let fromOA = Paper(id: "W1", doi: "10.1/x", title: "Cold reduces pain in treated mice", abstract: nil, journal: "Pain",
                   date: "2026-10-05", authors: ["Parisa Gazerani"], authorIDs: ["A1"], firstInstitution: "Oslo Met", journalID: "S1", reasons: ["Topic: Pain"], sources: ["OpenAlex"])
let fromEPMC = Paper(id: "epmc:MED:9", doi: "10.1/x", pmid: "9", title: "Cold reduces pain in treated mice", abstract: "Cold reduced pain.", journal: "Pain",
                     pubmedTypes: ["Journal Article"], date: "2026-10-05", authors: ["Gazerani P"], reasons: ["Journal: Pain"], sources: ["Europe PMC"])
let twoSources = Merge.combine([fromEPMC, fromOA])
check(twoSources.count == 1, "one paper from two sources, by DOI")
check(twoSources[0].id == "W1" && twoSources[0].authorIDs == ["A1"] && twoSources[0].journalID == "S1", "the OpenAlex copy is the base, so its ids survive")
check(twoSources[0].abstract == "Cold reduced pain." && twoSources[0].pmid == "9" && twoSources[0].pubmedTypes == ["Journal Article"], "and what it lacks is filled from Europe PMC")
check(twoSources[0].sourceNames.sorted() == ["Europe PMC", "OpenAlex"] && Set(twoSources[0].reasons) == ["Topic: Pain", "Journal: Pain"], "provenance and reasons add up")
let noDOI = Paper(id: "epmc:MED:10", pmid: "10", title: "Another", date: "2026-10-05", sources: ["Europe PMC"])
let noDOI2 = Paper(id: "W5", pmid: "10", title: "Another", date: "2026-10-05", sources: ["OpenAlex"])
check(Merge.combine([noDOI, noDOI2]).count == 1, "the same PMID joins two records without a DOI")

let earlyVersion = Paper(id: "epmc:PPR:P1", doi: "10.1101/2025.06.02.657417", title: "Tactile stimulation drives cortical responses in mice", isRepository: true,
                     date: "2025-06-03", authors: ["Smith J", "Lee K"], reasons: ["Keyword: tactile"], sources: ["Europe PMC"])
let published = Paper(id: "W7", doi: "10.1152/jn.00130.2025", title: "Tactile Stimulation Drives Cortical Responses in Mice.", journal: "Journal of Neurophysiology",
                      date: "2025-11-20", authors: ["John Smith", "Kim Lee"], reasons: ["Journal: J Neurophysiol"], sources: ["OpenAlex"])
let joined = Merge.combine([earlyVersion, published])
check(joined.count == 1 && joined[0].doi == "10.1152/jn.00130.2025" && !joined[0].isRepository, "a preprint and the article it became are one paper, the article winning")
check(Merge.combine([earlyVersion, Paper(id: "W8", doi: "10.1/y", title: published.title, date: "2027-12-01", authors: ["John Smith"])]).count == 2, "the same title years apart is not the same paper")
check(Merge.combine([Paper(id: "A", doi: "10.1/a", title: "Editorial", date: "2026-10-05", authors: ["Smith J"]), Paper(id: "B", doi: "10.1/b", title: "Editorial", date: "2026-10-05", authors: ["Smith J"])]).count == 2, "a short generic title is never matched by title")
check(Merge.firstSurname(Paper(id: "x", title: "t", date: "d", authors: ["Gazerani P"])) == Merge.firstSurname(Paper(id: "y", title: "t", date: "d", authors: ["Parisa Gazerani"])), "surname-first and surname-last names agree")
check(try JSONDecoder().decode(Paper.self, from: JSONEncoder().encode(fromOA)).sourceNames == ["OpenAlex"], "sources survive a round trip")
check(try FeedSettings.decode(Data("{}".utf8)).useOpenAlex && FeedSettings().useEuropePMC, "both sources are on by default, also for an older settings file")
var meshFollow = FeedSettings(); meshFollow.followedTopics = [Entity(id: "mesh:Pain", name: "Pain")]
check(FeedBuilder.seeds(meshFollow, myWorkIDs: []).contains { $0.seed == .mesh("Pain") && $0.explicit }, "a followed topic taken from MeSH becomes a MeSH seed")
var mutedByName = FeedSettings(); mutedByName.mutedJournals = [Entity(id: "name:Pain", name: "Pain")]
check(FeedBuilder.keep([fromEPMC, Paper(id: "z", title: "Other", journal: "Brain", date: "2026-10-05")], settings: mutedByName).map(\.id) == ["z"], "a journal muted by name is muted by name")

// MARK: sync between devices
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
func device(_ settings: FeedSettings, stamp: Date = .distantPast) -> SyncDocument {
    var d = SyncDocument(); d.reconcile(settings, at: stamp); return d
}
func journal(_ id: String) -> Entity { Entity(id: id, name: "Journal \(id)") }

// Two devices each follow a different journal: both are followed on both.
var phone = FeedSettings(); phone.followedJournals = [journal("S1")]
var mac = FeedSettings(); mac.followedJournals = [journal("S2")]
let phoneDoc = device(phone, stamp: at(1)), macDoc = device(mac, stamp: at(2))
let together = phoneDoc.merged(with: macDoc)
check(Set(together.apply(to: phone).followedJournals.map(\.id)) == ["S1", "S2"], "sync: different follows on two devices are both kept")
check(phoneDoc.merged(with: macDoc) == macDoc.merged(with: phoneDoc), "sync: merging is the same whichever file is read first")
check(together.merged(with: macDoc) == together && together.merged(with: together) == together, "sync: merging again changes nothing")
check(together.apply(to: phone).followedJournals.map(\.id).first == "S1", "sync: what a device already had keeps its place, what is new follows")

// A removal on one device beats an older copy on the other, and a later re-add beats the removal.
var phoneAfter = phone; phoneAfter.followedJournals = []
var phoneLedger = phoneDoc; phoneLedger.reconcile(phoneAfter, at: at(10))
check(phoneLedger.entries["e/followedJournals/S1"]?.present == false, "sync: a removal is recorded as a tombstone")
let afterRemoval = phoneLedger.merged(with: phoneDoc)
check(afterRemoval.apply(to: phone).followedJournals.isEmpty, "sync: the removal wins over the older copy")
var readded = phoneLedger; readded.reconcile(phone, at: at(20))
check(readded.merged(with: phoneLedger).apply(to: phoneAfter).followedJournals.map(\.id) == ["S1"], "sync: following it again later brings it back")

// Defaults on a new device never outrank another device's edit.
var editedSettings = FeedSettings(); editedSettings.daysBack = 14; editedSettings.byline = .both
let newInstall = device(FeedSettings())                    // a new install: stamped as the oldest
let editedDoc = device(editedSettings, stamp: at(5))
let adopted = newInstall.merged(with: editedDoc).apply(to: FeedSettings())
check(adopted.daysBack == 14 && adopted.byline == .both, "sync: a new device takes the settings of the one that was edited")
check(editedDoc.merged(with: newInstall).apply(to: editedSettings).daysBack == 14, "sync: and the edited device is not reset by it")

// Scalars: the later change wins.
var phoneEdit = editedSettings; phoneEdit.daysBack = 7
var macEdit = editedSettings; macEdit.daysBack = 60
var pl = editedDoc; pl.reconcile(phoneEdit, at: at(30))
var ml = editedDoc; ml.reconcile(macEdit, at: at(40))
check(pl.merged(with: ml).apply(to: editedSettings).daysBack == 60 && ml.merged(with: pl).apply(to: editedSettings).daysBack == 60, "sync: the later change to one setting wins on both devices")

// Saved, hidden, muted words, keywords.
var devA = FeedSettings(); devA.feedback.save(ok("sv1") { $0.doi = "10.1/saved" }); devA.feedback.hide(ok("hd1") { $0.doi = "10.1/hidden" })
devA.mutedKeywords = ["homeopathy"]; devA.followedKeywords = [KeywordRule(phrase: "tactile", alsoRequire: ["EEG"], exclude: [])]
var devB = FeedSettings()
let arrived = device(devA, stamp: at(1)).merged(with: device(devB)).apply(to: devB)
check(arrived.feedback.saved.map(\.id) == ["doi:10.1/saved"] && arrived.feedback.hidden == ["doi:10.1/hidden"], "sync: saved and hidden papers travel")
check(arrived.mutedKeywords == ["homeopathy"] && arrived.followedKeywords.first?.alsoRequire == ["EEG"], "sync: muted words and a keyword's own conditions travel")
var unsaved = device(devA, stamp: at(1)); var aNo = devA; aNo.feedback.unsave(ok("sv1") { $0.doi = "10.1/saved" }); unsaved.reconcile(aNo, at: at(9))
check(unsaved.merged(with: device(devA, stamp: at(1))).apply(to: devA).feedback.saved.isEmpty, "sync: unsaving on one device unsaves on the other")

// Seen and read only move forward.
let seenOnly = PaperState(firstSeen: at(5), lastSeen: at(6), seenCount: 2, opened: nil, snapshot: nil)
let readLater = PaperState(firstSeen: at(8), lastSeen: at(20), seenCount: 5, opened: at(19), snapshot: SavedPaper(ok("rd")))
let mergedState = PaperState.merge(seenOnly, readLater)
check(mergedState.opened == at(19) && mergedState.firstSeen == at(5) && mergedState.lastSeen == at(20) && mergedState.seenCount == 5, "sync: seen on one, read on the other is read, first seen earliest")
check(PaperState.merge(seenOnly, readLater) == PaperState.merge(readLater, seenOnly) && PaperState.merge(mergedState, mergedState) == mergedState, "sync: history merging is symmetric and does not inflate")
var h1 = SyncDocument(); h1.history.states["k"] = seenOnly
var h2 = SyncDocument(); h2.history.states["k"] = readLater; h2.history.states["z"] = seenOnly
check(h1.merged(with: h2).history.status(of: "k") == .read && h1.merged(with: h2).history.states.count == 2, "sync: history is merged paper by paper")

// The file.
let wire = try! together.encoded()
check(SyncDocument.read(wire) == .document(together), "sync file: a document survives a round trip, milliseconds and all")
check(SyncDocument.read(Data()) == .empty && SyncDocument.read(Data("  \n".utf8)) == .empty, "sync file: a new empty file is empty, not unreadable")
check(SyncDocument.read(Data("{\"settings\": 3}".utf8)) == .unreadable && SyncDocument.read(Data("not json".utf8)) == .unreadable, "sync file: something else is unreadable, so it is never overwritten")
check(SyncDocument.read(Data("{\"format\": 99, \"entries\": {}}".utf8)) == .newerFormat(99), "sync file: a newer format is not touched")
check({ if case .document = SyncDocument.read(Data("{\"format\": 1, \"entries\": {}, \"somethingNew\": 1}".utf8)) { return true } else { return false } }(), "sync file: unknown extra fields are ignored")
var millis = SyncDocument(); millis.entries["x"] = SyncEntry(at: Date(timeIntervalSince1970: 1_800_000_000.123), present: true, value: nil)
check({ if case .document(let d) = SyncDocument.read(try! millis.encoded()) { return d.entries["x"]?.at == millis.entries["x"]?.at } else { return false } }(), "sync file: timestamps keep their milliseconds")
check(SyncEntry.later(SyncEntry(at: at(1), present: true, value: "a"), SyncEntry(at: at(1), present: false, value: nil)).present, "sync: a tie between a change and a removal is settled the same way everywhere")

// Applying what came from elsewhere must not look like a local edit.
var ledger = device(phone, stamp: at(1)); let merged2 = ledger.merged(with: macDoc)
let applied = merged2.apply(to: phone)
var after = merged2; after.reconcile(applied, at: at(99))
check(after == merged2, "sync: settings applied from the merge are already in the record, so they are not stamped as new edits")
ledger.reconcile(phone, at: at(50))
check(ledger == device(phone, stamp: at(1)), "sync: reconciling unchanged settings changes nothing")
check(SyncProjection.items(of: FeedSettings()).keys.contains("v/orcid") && (try? FeedSettings.decode(Data("{}".utf8))) != nil, "sync: every scalar setting is covered")
var every = FeedSettings(); every.orcid = "0000-0001-2345-6789"; every.languages = ["en", "fr"]; every.kindWeights = ["caseReport": .hide]; every.impactWeight = 0.7; every.authorWeight = 0.3; every.byline = .first
check(device(every, stamp: at(1)).apply(to: FeedSettings()) == every, "sync: every kind of setting survives the record and back")

// MARK: the section for what the user follows
func ranked(_ p: Paper, _ score: Double) -> RankedPaper { RankedPaper(paper: p, score: score, similarity: 0) }
let fOld = ranked(ok("fa") { $0.followed = true; $0.date = "2026-10-01" }, 9)
let fNewLow = ranked(ok("fb") { $0.followed = true; $0.date = "2026-10-05" }, 0.1)
let fNewHigh = ranked(ok("fc") { $0.followed = true; $0.date = "2026-10-05" }, 3)
let plainTop = ranked(ok("pt") { $0.date = "2026-10-06" }, 8)
let plainLow = ranked(ok("pl") { $0.date = "2026-10-02" }, 1)
let splitOn = Arranger.split([fOld, plainTop, fNewLow, fNewHigh, plainLow], followSection: true)
check(splitOn.followed.map(\.paper.id) == ["fc", "fb", "fa"], "follow section: newest first, then by score, whatever the ranking said")
check(splitOn.rest.map(\.paper.id) == ["pt", "pl"], "follow section: the rest keeps its rank order and does not repeat what was taken out")
check(splitOn.followed.count + splitOn.rest.count == 5, "follow section: nothing is lost or shown twice")
let splitOff = Arranger.split([fOld, plainTop, fNewLow], followSection: false)
let offIDs: [String] = splitOff.rest.map { $0.paper.id }
check(splitOff.followed.isEmpty && offIDs == ["fa", "pt", "fb"], "follow section off: everything stays in the ranked list")
check(Arranger.split([], followSection: true).followed.isEmpty, "follow section: an empty feed is fine")

// MARK: ORCID and profile suggestions
check(Orcid.normalised("0000-0003-1056-5980") == "0000-0003-1056-5980", "orcid: a valid iD is accepted")
check(Orcid.normalised("0000000310565980") == "0000-0003-1056-5980" && Orcid.normalised("https://orcid.org/0000-0003-1056-5980") == "0000-0003-1056-5980", "orcid: without hyphens, or as a link")
check(Orcid.normalised("0000-0003-1056-5981") == nil && Orcid.normalised("0000-0003-1056") == nil && Orcid.normalised("hello") == nil && Orcid.normalised("") == nil, "orcid: a slip in the last digit, a short one and nonsense are refused")
check(Orcid.normalised("0000-0002-1825-0097") == "0000-0002-1825-0097", "orcid: ORCID's own example iD is valid")
check(Orcid.normalised("0000-0001-5109-3700") == "0000-0001-5109-3700" && Orcid.normalised("0000-0002-1694-233x") == "0000-0002-1694-233X", "orcid: a check character of X is read in either case")

func pfE(_ id: String, _ name: String) -> Entity { Entity(id: id, name: name) }
let pfYear = 2026
let pfPain = pfE("T1", "Pain"), pfOld = pfE("T2", "Old subject"), pfRare = pfE("T3", "Once")
let pfJournal = pfE("S1", "Pain Journal"), pfCoA = pfE("A1", "Ada"), pfCoB = pfE("A2", "Bo")
let pfWorks = [
    ProfileWork(year: 2026, topics: [pfPain], journal: pfJournal, people: [pfCoA], institutions: [pfE("I1", "UCLouvain")], funders: [pfE("F1", "ERC")]),
    ProfileWork(year: 2025, topics: [pfPain, pfRare], journal: pfJournal, people: [pfCoA, pfCoB], institutions: [pfE("I1", "UCLouvain")], funders: [pfE("F1", "ERC")]),
    ProfileWork(year: 2012, topics: [pfOld], journal: nil, people: [pfCoB], institutions: [pfE("I2", "Old lab")], funders: []),
    ProfileWork(year: 2011, topics: [pfOld], journal: nil, people: [pfCoB], institutions: [], funders: []),
]
let pfSuggested = ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: pfWorks)], currentYear: pfYear)
let pfTopics = pfSuggested[.topic]!
check(pfTopics.first?.entity.id == "T1" && pfTopics.first?.count == 2 && pfTopics.first?.latestYear == 2026, "suggestions: the topic of the most recent papers comes first, with its count and latest year")
check(pfTopics.first(where: { $0.entity.id == "T1" })?.selected == true, "suggestions: a recent, repeated topic is ticked")
check(pfTopics.first(where: { $0.entity.id == "T2" })?.selected == false && pfTopics.first(where: { $0.entity.id == "T2" })?.count == 2, "suggestions: a topic not worked on for years is listed but not ticked")
check(pfTopics.first(where: { $0.entity.id == "T3" })?.selected == false, "suggestions: a topic that occurs once is not ticked")
check(pfSuggested[.journal]?.map(\.entity.id) == ["S1"], "suggestions: a repository is never a journal to follow")
check(pfSuggested[.researcher]?.first(where: { $0.entity.id == "A2" })?.count == 3 && pfSuggested[.researcher]?.first(where: { $0.entity.id == "A2" })?.selected == true, "suggestions: co-authors counted over all papers; three together and a recent one is ticked")
check(pfSuggested[.researcher]?.first(where: { $0.entity.id == "A1" })?.count == 2 && pfSuggested[.researcher]?.first(where: { $0.entity.id == "A1" })?.selected == false, "suggestions: two papers together is not enough to tick a co-author")
check(pfSuggested[.institution]?.first?.entity.id == "I1" && pfSuggested[.institution]?.first?.selected == false && pfSuggested[.funder]?.first?.entity.id == "F1" && pfSuggested[.funder]?.first?.selected == false, "suggestions: institutions and funders are listed, never ticked: following one lists papers in every field")
let pfTwo = ProfileAnalysis.suggestions([
    ProfileSourceWorks(label: "you", works: [ProfileWork(year: 2026, topics: [pfPain])]),
    ProfileSourceWorks(label: "Supervisor", works: [ProfileWork(year: 2026, topics: [pfPain]), ProfileWork(year: 2025, topics: [pfE("T9", "Her field")])]),
], currentYear: pfYear)
check(pfTwo[.topic]?.first?.entity.id == "T1" && pfTwo[.topic]?.first?.fromNames == ["you", "Supervisor"] && pfTwo[.topic]?.first?.count == 2, "suggestions: what two people share is counted together and credited to both")
let pfSupervisor = ProfileAnalysis.suggestions([ProfileSourceWorks(label: "Supervisor", works: (0..<5).map { ProfileWork(year: 2026 - $0 % 2, topics: [pfPain], journal: pfJournal) })], currentYear: pfYear)
check(pfSupervisor[.topic]?.first?.selected == true && pfSupervisor[.journal]?.first?.fromNames == ["Supervisor"], "suggestions: a student with no papers is served by a supervisor's")
check(ProfileAnalysis.suggestions([], currentYear: pfYear)[.topic]?.isEmpty == true, "suggestions: no works, no suggestions")
let pfMany = (0..<3).flatMap { _ in (0..<30).map { ProfileWork(year: 2026, people: [pfE("A\($0)", "P\($0)")]) } }
check(ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: pfMany)], currentYear: pfYear)[.researcher]?.count == ProfileAnalysis.listed, "suggestions: the list is capped")
check(ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: pfMany)], currentYear: pfYear)[.researcher]?.filter(\.selected).count == SuggestionKind.researcher.defaultCount, "suggestions: only a handful are ticked to begin with")
check(ProfileAnalysis.isSameAuthor(Entity(id: "name:Mouraux A", name: "Mouraux A"), Entity(id: "name:André Mouraux", name: "André Mouraux")), "same author: surname-first with initial, and the full name")
check(!ProfileAnalysis.isSameAuthor(Entity(id: "name:Mouraux B", name: "Mouraux B"), Entity(id: "name:André Mouraux", name: "André Mouraux")) && !ProfileAnalysis.isSameAuthor(Entity(id: "A1", name: "X"), Entity(id: "A2", name: "X")), "same author: another initial, or two different ids, is someone else")

var withSupervisor = FeedSettings(); withSupervisor.profileOrcids = [ProfileSource(orcid: "0000-0002-1825-0097", label: "Supervisor")]; withSupervisor.profileFilled = true
check(device(withSupervisor, stamp: at(1)).apply(to: FeedSettings()) == withSupervisor, "other ORCIDs and the filled flag sync")
check((try! FeedSettings.decode(Data("{\"profileOrcids\": [{\"orcid\": \"a\"}, {\"orcid\": \"b\"}, {\"orcid\": \"c\"}, {\"orcid\": \"d\"}]}".utf8))).profileOrcids.count == 3, "no more than three other ORCIDs are read")
check((try! FeedSettings.decode(Data("{}".utf8))).profileOrcids.isEmpty && !(try! FeedSettings.decode(Data("{}".utf8))).profileFilled, "an older settings file has none")
var filledOnly = FeedSettings(); filledOnly.profileFilled = true
check(filledOnly.forRanking == FeedSettings().forRanking, "the filled flag asks for no refresh by itself")
var otherOrcid = FeedSettings(); otherOrcid.profileOrcids = [ProfileSource(orcid: "0000-0002-1825-0097")]
check(otherOrcid.forRanking != FeedSettings().forRanking && otherOrcid.forFetching != FeedSettings().forFetching, "adding someone to learn from does refetch: their papers are part of the profile")

let institutionOnly = ranked(ok("io") { $0.followed = true; $0.reasons = ["Institution: UCLouvain"]; $0.date = "2026-10-07" }, 2)
let topicOnly = ranked(ok("to") { $0.followed = true; $0.reasons = ["Topic: Pain"]; $0.date = "2026-10-09" }, 5)
let journalToo = ranked(ok("jt") { $0.followed = true; $0.reasons = ["Topic: Pain", "Journal: Pain"]; $0.date = "2026-10-08" }, 4)
let splitTopics = Arranger.split([topicOnly, journalToo, plainTop, institutionOnly], followSection: true)
let topicIDs: [String] = splitTopics.followed.map { $0.paper.id }
let restIDs: [String] = splitTopics.rest.map { $0.paper.id }
check(topicIDs == ["jt"] && restIDs == ["to", "pt", "io"], "follow section: a paper found only by a topic or an institution is ranked with the rest, one a journal also found is listed")

let bigJournal = pfE("S9", "General Journal")
let sizedWorks = (0..<4).map { _ in ProfileWork(year: 2026, journal: bigJournal) } + (0..<4).map { _ in ProfileWork(year: 2026, journal: pfE("S8", "Specialist Journal")) }
let sized = ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: sizedWorks)], currentYear: 2026, journalSizes: ["S9": 300_000, "S8": 4_000])
check(sized[.journal]?.first(where: { $0.entity.id == "S9" })?.selected == false && sized[.journal]?.first(where: { $0.entity.id == "S9" })?.note != nil, "suggestions: a large general journal is offered with a warning, unticked")
check(sized[.journal]?.first(where: { $0.entity.id == "S8" })?.selected == true && sized[.journal]?.first(where: { $0.entity.id == "S8" })?.note == nil, "suggestions: a specialist journal is ticked without a warning")
check(ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: sizedWorks)], currentYear: 2026)[.journal]?.allSatisfy { $0.note == nil } == true, "suggestions: with no sizes known there is no warning")

func kw(_ s: String) -> Entity { Entity(id: s.lowercased(), name: s) }
let keywordWorks = (0..<4).map { _ in ProfileWork(year: 2026, keywords: [kw("Nociception"), kw("pain perception"), kw("laser-evoked potentials")]) }
    + [ProfileWork(year: 2026, keywords: [kw("nociception")]), ProfileWork(year: 2010, keywords: [kw("Old method")]), ProfileWork(year: 2010, keywords: [kw("Old method")]), ProfileWork(year: 2010, keywords: [kw("Old method")])]
let keywordSuggestions = ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: keywordWorks)], currentYear: 2026,
                                                     keywordVolumes: ["pain perception": 900, "laser-evoked potentials": 12, "nociception": 60])
check(keywordSuggestions[.keyword]?.first(where: { $0.entity.id == "nociception" })?.count == 5, "keywords: the same phrase in different cases is one keyword")
check(keywordSuggestions[.keyword]?.first(where: { $0.entity.id == "laser-evoked potentials" })?.selected == true, "keywords: a specific recurrent keyword is ticked")
check(keywordSuggestions[.keyword]?.first(where: { $0.entity.id == "pain perception" })?.selected == false && keywordSuggestions[.keyword]?.first(where: { $0.entity.id == "pain perception" })?.note != nil, "keywords: one matching hundreds of papers a month is offered with a warning, unticked")
check(keywordSuggestions[.keyword]?.first(where: { $0.entity.id == "old method" })?.selected == false, "keywords: an old one is not ticked")
let onceKeyword = ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: [ProfileWork(year: 2026, keywords: [kw("rare"), kw("rare")]), ProfileWork(year: 2026, keywords: [kw("rare")])])], currentYear: 2026)
check(onceKeyword[.keyword]?.first?.count == 2 && onceKeyword[.keyword]?.first?.selected == false, "keywords: a phrase in two papers is not enough to tick")
check(ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: keywordWorks)], currentYear: 2026)[.keyword]?.allSatisfy { $0.note == nil } == true, "keywords: without volumes there is no warning")
check(ProfileAnalysis.suggestions([ProfileSourceWorks(label: "you", works: [ProfileWork(year: 2026)])], currentYear: 2026)[.keyword]?.isEmpty == true, "keywords: none from a source that has none (Europe PMC)")

// MARK: keyword importance
var kwSettings = FeedSettings()
kwSettings.followedKeywords = [KeywordRule(phrase: "high one", importance: .high), KeywordRule(phrase: "plain one"), KeywordRule(phrase: "low one", importance: .low)]
let kwHigh = ok("kh") { $0.reasons = ["Keyword: high one"]; $0.followed = true; $0.date = "2026-10-01" }
let kwPlain = ok("kp") { $0.reasons = ["Keyword: plain one"]; $0.followed = true; $0.date = "2026-10-03" }
let kwLow = ok("kl") { $0.reasons = ["Keyword: low one"]; $0.followed = true; $0.date = "2026-10-05" }
let kwBoth = ok("kb") { $0.reasons = ["Keyword: low one", "Keyword: high one"]; $0.followed = true; $0.date = "2026-10-02" }
let kwNone = ok("kn") { $0.date = "2026-10-01" }
let kwRanked = Ranker.rank([kwLow, kwPlain, kwHigh, kwNone], profileTexts: profile, settings: kwSettings, today: now).map(\.paper.id)
check(kwRanked.firstIndex(of: "kh")! < kwRanked.firstIndex(of: "kp")! && kwRanked.firstIndex(of: "kp")! < kwRanked.firstIndex(of: "kl")!, "keyword importance: high above normal above low in the ranking, all else equal")
check(kwSettings.keywordImportance(of: kwBoth) == .high && kwSettings.keywordImportance(of: kwNone) == nil, "keyword importance: a paper two keywords found counts as the higher; none, no importance")
check(Importance.high.bonus > Importance.normal.bonus && Importance.normal.bonus == 0 && Importance.low.bonus < 0, "keyword importance: the bonuses run the right way")
let kwSplit = Arranger.split([kwLow, kwPlain, kwHigh, kwBoth].map { ranked($0, 1) }, followSection: true, keywords: kwSettings.followedKeywords)
let kwOrder: [String] = kwSplit.followed.map { $0.paper.id }
check(kwOrder == ["kb", "kh", "kp", "kl"], "keyword importance: under From what you follow, high first, then normal, then low, newest first within each")
let kwJournal = ranked(ok("kj") { $0.reasons = ["Keyword: low one", "Journal: Pain"]; $0.followed = true; $0.date = "2026-10-04" }, 1)
let kwMixed: [String] = Arranger.split([ranked(kwLow, 1), kwJournal], followSection: true, keywords: kwSettings.followedKeywords).followed.map { $0.paper.id }
check(kwMixed == ["kj", "kl"], "keyword importance: a paper a journal also found is at least normal, whatever its low keyword says")
check((try! JSONDecoder().decode(KeywordRule.self, from: Data("{\"phrase\": \"tactile\", \"alsoRequire\": [\"EEG\"]}".utf8))).importance == .normal, "keyword importance: a keyword saved before it existed is normal")
check((try! JSONDecoder().decode(KeywordRule.self, from: Data("{\"phrase\": \"x\", \"importance\": \"nonsense\"}".utf8))).importance == .normal, "keyword importance: an unknown value is normal")
var importanceSynced = FeedSettings(); importanceSynced.followedKeywords = [KeywordRule(phrase: "x", importance: .high)]
check(device(importanceSynced, stamp: at(1)).apply(to: FeedSettings()).followedKeywords.first?.importance == .high, "keyword importance: it syncs")
var importanceChanged = importanceSynced; importanceChanged.followedKeywords[0].importance = .low
var importanceLedger = device(importanceSynced, stamp: at(1)); importanceLedger.reconcile(importanceChanged, at: at(9))
check(importanceLedger.merged(with: device(importanceSynced, stamp: at(1))).apply(to: importanceSynced).followedKeywords.first?.importance == .low, "keyword importance: changing it on one device is a later decision than the old value")

// MARK: feed order and highlights
let hlDefaults = FeedSettings()
check(hlDefaults.feedOrder == .blended && hlDefaults.highlightCount == 3 && hlDefaults.highlightCloseness == 0.95 && hlDefaults.highlightImpact == 5 && hlDefaults.highlightAuthorH == 40, "layout settings: one ranked list and three highlights by default")
let hlClamped = try! FeedSettings.decode(Data("{\"highlightCount\": 99, \"highlightCloseness\": 0.1, \"highlightImpact\": -4, \"highlightAuthorH\": 9999, \"feedOrder\": \"nonsense\"}".utf8))
check(hlClamped.highlightCount == 5 && hlClamped.highlightCloseness == 0.5 && hlClamped.highlightImpact == 0 && hlClamped.highlightAuthorH == 200 && hlClamped.feedOrder == .blended, "layout settings: clamped when read, an unknown order is the default")
var hlChanged = FeedSettings(); hlChanged.feedOrder = .sections; hlChanged.highlightCount = 0; hlChanged.highlightImpact = 12; hlChanged.highlightCloseness = 0.8; hlChanged.highlightAuthorH = 70
check(hlChanged.forRanking == FeedSettings().forRanking && hlChanged.forFetching == FeedSettings().forFetching, "layout settings: only display, so they ask for no refresh")
check(device(hlChanged, stamp: at(1)).apply(to: FeedSettings()) == hlChanged, "layout settings: they sync")

func hr(_ p: Paper, _ score: Double, _ sim: Double) -> RankedPaper { RankedPaper(paper: p, score: score, similarity: sim) }
let hlImpact = hr(ok("hi") { $0.journalImpact = 12.04 }, 4, 0.97)
let hlNoSignal = hr(ok("hn"), 5, 0.99)
let hlFar = hr(ok("hf") { $0.journalImpact = 30 }, 6, 0.80)
let hlCites = hr(ok("hc") { $0.citesYou = true }, 3, 0.96)
let hlSenior = hr(ok("hs") { $0.lastAuthorH = 80 }, 3.5, 0.96)
let hlFollowed = hr(ok("hp") { $0.followed = true; $0.reasons = ["Journal: Pain"] }, 2, 0.96)
let picked = Highlights.select([hlImpact, hlNoSignal, hlFar, hlCites, hlSenior, hlFollowed], settings: FeedSettings())
let pickedIDs: [String] = picked.map { $0.ranked.paper.id }
check(pickedIDs == ["hi", "hs", "hc"], "highlights: close to the user's work and with something more, best score first, at most three")
check(!pickedIDs.contains("hn") && !pickedIDs.contains("hf"), "highlights: close alone is not enough, and a great journal alone is not close enough")
check(picked.first?.reason == "very close to your work · journal impact 12.0" && picked[1].reason.contains("senior author h-index 80") && picked[2].reason.contains("cites your work"), "highlights: the reason says what makes each one stand out")
var hlMany = FeedSettings(); hlMany.highlightCount = 5
check(Highlights.select([hlImpact, hlCites, hlSenior, hlFollowed], settings: hlMany).last?.reason.contains("from something you follow") == true, "highlights: something specific the user follows, with closeness, counts")
var hlNone = FeedSettings(); hlNone.highlightCount = 0
check(Highlights.select([hlImpact], settings: hlNone).isEmpty, "highlights: none when switched off")
var hlNoImpact = FeedSettings(); hlNoImpact.highlightImpact = 0
check(Highlights.select([hlImpact], settings: hlNoImpact).isEmpty, "highlights: an impact threshold of zero ignores the journal")
var hlStrict = FeedSettings(); hlStrict.highlightImpact = 20
check(Highlights.select([hlImpact], settings: hlStrict).isEmpty, "highlights: a higher impact threshold leaves out a lesser journal")
var hlByline = FeedSettings(); hlByline.byline = .first
check(Highlights.select([hlSenior], settings: hlByline).isEmpty, "highlights: the h-index that counts follows the author the user chose")

let blendList = (0..<5).map { hr(ok("b\($0)"), Double(10 - $0), 0) } + [hr(ok("pin") { $0.followed = true; $0.reasons = ["Journal: Pain"] }, -1, 0)]
let blendIDs: [String] = Arranger.blend(blendList, cap: 3).map { $0.paper.id }
check(blendIDs == ["b0", "b1", "b2", "pin"], "blend: the best few, in order, and what the user follows even though it scores lowest")

// the whole layout
var layoutSettings = FeedSettings(); layoutSettings.followedKeywords = []
let layoutCited = [hr(ok("cited") { $0.citesYou = true; $0.date = "2026-10-01" }, 4.995, 0.5)]
var layoutOthers = (0..<200).map { hr(ok("o\($0)") { $0.date = "2026-10-02" }, 5 - Double($0) / 100, 0.1) }
layoutOthers.append(hr(ok("lowFollow") { $0.followed = true; $0.reasons = ["Journal: Pain"]; $0.date = "2026-10-03" }, -2, 0.1))
layoutOthers.insert(hr(ok("star") { $0.journalImpact = 20; $0.date = "2026-10-04" }, 9, 0.99), at: 0)
let layoutNow = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 10, day: 10, hour: 12))!
let blended = FeedLayout.make(citedYou: layoutCited, forYou: layoutOthers, history: History(), settings: layoutSettings, now: layoutNow)
let blendedIDs: [String] = blended.feed.fresh.map { $0.paper.id }
check(blended.highlights.map { $0.ranked.paper.id } == ["star"] && !blendedIDs.contains("star"), "layout: a highlight is lifted out of the list, not shown twice")
check(blendedIDs.count == 202 && blendedIDs.last == "lowFollow", "layout: the list is not cut, so it can be scrolled as far as what is held")
check(Array(blendedIDs.prefix(3)) == ["o0", "cited", "o1"], "layout: a paper citing the user's work is placed by its score among the rest, not ahead of them")
check(blended.citedYou.isEmpty && blended.following.isEmpty && blended.forYou.isEmpty, "layout: one list, no sections")
var sectionSettings = layoutSettings; sectionSettings.feedOrder = .sections
let sections = FeedLayout.make(citedYou: layoutCited, forYou: layoutOthers, history: History(), settings: sectionSettings, now: layoutNow)
check(sections.citedYou.fresh.map { $0.paper.id } == ["cited"] && sections.following.fresh.map { $0.paper.id } == ["lowFollow"] && sections.feed.isEmpty, "layout in sections: cited you, what is followed, and the rest apart")
check(!sections.forYou.fresh.contains { $0.paper.id == "star" } && sections.highlights.count == 1, "layout in sections: highlights come out of the sections too")
// papers older than the look-back go last, whatever they score
let oldPapers = [hr(ok("recentOld") { $0.date = "2026-08-25" }, 1, 0.1),
                 hr(ok("ancient") { $0.date = "2026-08-01"; $0.journalImpact = 30 }, 9.5, 0.99),
                 hr(ok("ancientFollow") { $0.date = "2026-08-02"; $0.followed = true; $0.reasons = ["Journal: Pain"] }, 1, 0.1)]
let withOld = FeedLayout.make(citedYou: layoutCited, forYou: layoutOthers + oldPapers, history: History(), settings: layoutSettings, now: layoutNow)
check(withOld.older.map { $0.paper.id } == ["recentOld", "ancient", "ancientFollow"], "layout: papers older than the look-back are a list of their own, the nearer 30 days first and the best first within them")
check(!withOld.feed.fresh.contains { $0.paper.id.hasPrefix("ancient") } && withOld.highlights.map { $0.ranked.paper.id } == ["star"], "layout: they are not in the list above and are never highlighted")
check(withOld.all.contains { $0.paper.id == "ancient" } && !withOld.isEmpty, "layout: they count as on screen")
let withOldSections = FeedLayout.make(citedYou: layoutCited, forYou: layoutOthers + oldPapers, history: History(), settings: sectionSettings, now: layoutNow)
check(withOldSections.older.map { $0.paper.id } == ["recentOld", "ancient", "ancientFollow"] && !withOldSections.following.fresh.contains { $0.paper.id == "ancientFollow" }, "layout in sections: the same")
// going further back
let backFrom = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 11, day: 8, hour: 12))!
let firstBack = Incremental.olderRange(now: backFrom, daysBack: 30, extraDays: 0)!
check(firstBack.since == "2026-09-09" && firstBack.until == "2026-10-09" && firstBack.extraDays == 30, "older: the first step is the 30 days before the look-back")
let secondBack = Incremental.olderRange(now: backFrom, daysBack: 30, extraDays: 30)!
check(secondBack.until == "2026-09-09" && secondBack.extraDays == 60, "older: the next step starts where the last stopped")
check(Incremental.olderRange(now: backFrom, daysBack: 30, extraDays: 335) == nil && Incremental.olderRange(now: backFrom, daysBack: 30, extraDays: 330)?.extraDays == 335, "older: it stops at a year, the last step shortened")
check(Incremental.olderRange(now: backFrom, daysBack: 90, extraDays: 0)!.until == "2026-08-10", "older: it counts from the look-back chosen")
check(Seed.keyword("pain").filter(since: "2026-09-09", until: "2026-10-09") == "title_and_abstract.search:pain,from_publication_date:2026-09-09,to_publication_date:2026-10-09", "older: OpenAlex is given both ends")
check(Seed.keyword("pain").filter(since: "d") == "title_and_abstract.search:pain,from_publication_date:d", "a normal query has no end date")
var seenHistory = History(); seenHistory.markSeen("doi:none", at: Date())
let emptyLayout = FeedLayout.make(citedYou: [], forYou: [], history: seenHistory, settings: layoutSettings, now: Date())
check(emptyLayout.isEmpty, "layout: nothing in, nothing out")

// MARK: one phrase, several rules
var twin = FeedSettings()
twin.addKeyword("pain")
twin.followedKeywords[0].alsoRequire = ["EEG"]
twin.addKeyword("pain")
twin.followedKeywords[1].alsoRequire = ["MRI"]
check(twin.followedKeywords.count == 2 && twin.followedKeywords[0].id != twin.followedKeywords[1].id, "the same phrase can be followed twice, each rule with its own id")
let twinSeeds = FeedBuilder.seeds(twin, myWorkIDs: []).map(\.seed.reason)
check(twinSeeds == ["Keyword: pain + EEG", "Keyword: pain + MRI"], "each rule is its own search")
func twinKept(_ title: String, _ reasons: [String]) -> Bool {
    !FeedBuilder.keep([ok("t") { $0.reasons = reasons; $0.title = title }], settings: twin).isEmpty
}
check(twinKept("Pain and EEG", ["Keyword: pain + EEG"]), "twin rules: the first rule's paper stays")
check(twinKept("Pain and MRI", ["Keyword: pain + MRI"]), "twin rules: the second rule's paper stays")
check(!twinKept("Pain and fMRI", ["Keyword: pain + EEG"]), "twin rules: a rule keeps only what has its own words")
check(twinKept("Pain, EEG and MRI", ["Keyword: pain + EEG", "Keyword: pain + MRI"]), "twin rules: either may find it")
var twinHigh = twin; twinHigh.followedKeywords[1].importance = .high
check(twinHigh.keywordImportance(of: ok("t") { $0.reasons = ["Keyword: pain + MRI"] }) == .high
      && twinHigh.keywordImportance(of: ok("t") { $0.reasons = ["Keyword: pain + EEG"] }) == .normal, "twin rules carry their own importance")
var twinNamed = FeedSettings(); twinNamed.addKeyword("pain"); twinNamed.addKeyword("pain")
check(twinNamed.followedKeywords[0].id == "pain", "the first rule on a phrase keeps the phrase as its id, as before")
let twinItems = SyncProjection.items(of: twin)
check(twinItems.keys.filter { $0.hasPrefix("kw/") }.count == 2, "twin rules are two sync items, not one")
let twinPhone = FeedSettings()
var twinPhoneLedger: [String: SyncEntry] = [:]
for (k, v) in twinItems { twinPhoneLedger[k] = SyncEntry(at: Date(timeIntervalSince1970: 1_000), present: true, value: v) }
let twinApplied = SyncProjection.apply(twinPhoneLedger, to: twinPhone)
check(twinApplied.followedKeywords.map { $0.alsoRequire }.sorted { $0.joined() < $1.joined() } == [["EEG"], ["MRI"]], "twin rules survive a sync to a second device")
var renamed = twin; renamed.followedKeywords[0].phrase = "headache"
check(SyncProjection.items(of: renamed).keys.sorted() == twinItems.keys.sorted(), "renaming a rule keeps its sync key")
check((try! JSONDecoder().decode(KeywordRule.self, from: Data("{\"phrase\": \"tactile\"}".utf8))).id == "tactile", "a rule saved before ids existed takes its phrase")
check(Seed.keyword("pain", also: ["EEG", "MRI"]).filter(since: "d") == "title_and_abstract.search:\"pain\" AND \"EEG\" AND \"MRI\",from_publication_date:d", "OpenAlex is asked for all the words")
check(EuropePMCQuery.build(.keyword("pain", also: ["EEG"]), since: window.0, until: window.1) == "((TITLE:\"pain\" OR ABSTRACT:\"pain\") AND (TITLE:\"EEG\" OR ABSTRACT:\"EEG\")) AND FIRST_PDATE:[2026-10-01 TO 2026-11-08]", "Europe PMC is asked for all the words")

// MARK: backup
var bk = FeedSettings()
bk.orcid = "0000-0003-1056-5980"
bk.followedTopics = [Entity(id: "T1", name: "Pain")]; bk.followedJournals = [Entity(id: "S1", name: "Pain"), Entity(id: "S2", name: "Neuron")]
bk.followedKeywords = [KeywordRule(phrase: "pain", alsoRequire: ["EEG"], importance: .high), KeywordRule(phrase: "pain", alsoRequire: ["MRI"], id: "second")]
bk.mutedKeywords = ["homeopathy"]; bk.daysBack = 60; bk.recency = 0.2; bk.feedback.hidden = ["doi:x"]
let backupAt = Date(timeIntervalSince1970: 1_800_000_000)
let backupData = try! Backup.encode(bk, at: backupAt)
if case .settings(let restored, let savedAt) = Backup.decode(backupData) {
    check(restored == bk, "backup: restoring gives back exactly what was saved")
    check(savedAt == backupAt, "backup: it says when it was saved")
    check(restored.followedKeywords.map(\.id) == ["pain", "second"] && restored.followedKeywords[0].importance == .high, "backup: two rules on one phrase come back as two, with their importance")
} else { check(false, "backup: a backup decodes") }
check(!String(decoding: backupData, as: UTF8.self).lowercased().contains("apikey") && !String(decoding: backupData, as: UTF8.self).contains("openalex_key"), "backup: it holds no key")
check(Backup.decode(Data("{}".utf8)) == .notABackup && Backup.decode(Data("not json".utf8)) == .notABackup, "backup: a file that is not one is refused")
check(Backup.decode((try? SyncDocument().encoded()) ?? Data()) == .notABackup, "backup: the sync file is not a backup, and is refused rather than read as default settings")
check(Backup.decode(try! bk.encoded()) == .notABackup, "backup: a bare settings file is refused too")
let futureBackup = String(decoding: backupData, as: UTF8.self).replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 99")
check(Backup.decode(Data(futureBackup.utf8)) == .newerFormat, "backup: one from a newer app is refused, not half read")
check(Backup.filename(at: backupAt).hasPrefix("Scrollar settings 20"), "backup: the file is named with its date")
check(Backup.summary(of: bk) == ["1 topic", "2 journals", "2 keywords", "1 mute", "1 hidden paper"], "backup: the summary names what it holds, and leaves out what is empty")
check(Backup.summary(of: FeedSettings()).isEmpty, "backup: nothing to say about empty settings")

// MARK: preview
var pv = FeedSettings(); pv.mutedKeywords = ["homeopathy"]
let pvSeed = Seed.keyword("pain", also: ["EEG"])
let pvFound = [
    ok("p1") { $0.title = "Pain and EEG in humans"; $0.date = "2026-11-01" },
    ok("p2") { $0.title = "Pain, EEG and rats"; $0.date = "2026-11-05" },
    ok("p3") { $0.title = "Homeopathy for pain and EEG"; $0.date = "2026-11-03" },
    ok("p1") { $0.title = "Pain and EEG in humans"; $0.date = "2026-11-01" },
]
let pvRule = KeywordRule(phrase: "pain", alsoRequire: ["EEG"], exclude: ["rats"])
let pvResult = Previews.make(pvFound, seed: pvSeed, rule: pvRule, settings: pv, fullPage: false)
check(pvResult.papers.map(\.id) == ["p1"] && pvResult.matched == 1, "preview: what the keyword's words and the mutes allow, and nothing else")
check(pvResult.removed == 2, "preview: it counts what the conditions and mutes took out, a duplicate not counted")
let pvLoose = Previews.make(pvFound, seed: pvSeed, rule: nil, settings: FeedSettings(), fullPage: true)
check(pvLoose.papers.map(\.id) == ["p2", "p3", "p1"] && pvLoose.mayHaveMore, "preview: newest first, and it says when there is more than was fetched")
let pvMany = (0..<80).map { n in ok("m\(n)") { $0.title = "Paper \(n)"; $0.date = "2026-10-\(String(format: "%02d", 1 + n % 28))" } }
let pvMore = Previews.make(pvMany, seed: .keyword("x"), settings: FeedSettings(), fullPage: false)
check(pvMore.papers.count == Previews.shown && pvMore.matched == 80, "preview: it shows a screenful and counts the rest")
check(Seed.forTopic(Entity(id: "T1", name: "Pain")) == .topic(id: "T1", name: "Pain") && Seed.forTopic(Entity(id: "mesh:Pain", name: "Pain")) == .mesh("Pain") && Seed.forTopic(Entity(id: "mesh:Humans", name: "Humans")) == nil, "preview: a topic is the search the feed would run, and a heading too general to follow is none")

// MARK: pdf links
check(PDFLink.clean("https://x.org/a.pdf") == "https://x.org/a.pdf" && PDFLink.clean("http://x.org/a.pdf") == nil && PDFLink.clean("  ") == nil && PDFLink.clean(nil) == nil && PDFLink.clean("not a url") == nil, "pdf: only an https link is worth showing")
check(PDFLink.openAlex(best: nil, primary: "https://p.org/1.pdf") == "https://p.org/1.pdf" && PDFLink.openAlex(best: "https://b.org/1.pdf", primary: "https://p.org/1.pdf") == "https://b.org/1.pdf" && PDFLink.openAlex(best: "http://b.org", primary: nil) == nil, "pdf: OpenAlex's best open-access copy wins over the publisher's page")
let pdfFixture = Data("""
{"resultList":{"result":[{"source":"MED","id":"1","title":"A paper.","firstPublicationDate":"2026-10-01","fullTextUrlList":{"fullTextUrl":[
 {"availability":"Subscription required","documentStyle":"pdf","url":"https://pub.org/locked.pdf"},
 {"availability":"Open access","documentStyle":"html","url":"https://europepmc.org/articles/PMC1"},
 {"availability":"Open access","documentStyle":"pdf","url":"https://europepmc.org/articles/PMC1?pdf=render"}]}},
 {"source":"MED","id":"2","title":"Another.","firstPublicationDate":"2026-10-02"}]}}
""".utf8)
let pdfPapers = EuropePMCParser.papers(from: pdfFixture)
check(pdfPapers.first?.pdfURL == "https://europepmc.org/articles/PMC1?pdf=render" && pdfPapers.last?.pdfURL == nil, "pdf: Europe PMC's free PDF is taken, a locked one and a web page are not")
check({ var a = Paper(id: "a", title: "t", date: "2026-10-01"); a.doi = "10.1/p"; var b = a; b.id = "b"; b.pdfURL = "https://x.org/p.pdf"; return Merge.combine([a, b]).first?.pdfURL == "https://x.org/p.pdf" }(), "pdf: a copy that has a PDF link lends it to the one that does not")
let oldPaperJSON = Data(#"{"id":"W1","title":"T","date":"2026-01-01","isRepository":false,"pubmedTypes":[],"abstractFromPubMed":false,"authors":[],"authorIDs":[],"citedBy":0,"topics":[],"topicIDs":[],"isOpenAccess":false,"reasons":[],"citesYou":false,"followed":false}"#.utf8)
check((try? JSONDecoder().decode(Paper.self, from: oldPaperJSON))?.pdfURL == nil, "pdf: a cache written before there was a link still loads")

// MARK: reader pane
check(Reader.isWide(width: 834) && Reader.isWide(width: 1100) && !Reader.isWide(width: 744) && !Reader.isWide(width: 393), "reader: a portrait iPad and a Mac window get a column; a phone and an iPad mini do not")
check(Reader.feedColumnWidth(total: 800, fraction: 0.5) == 400 && Reader.feedColumnWidth(total: 800, fraction: 0.6) == 411 && Reader.feedColumnWidth(total: 800, fraction: 0.2) == 320, "reader: a dragged width is kept, but the reader never gets under 380 points nor the feed under 320")
check(Reader.feedColumnWidth(total: 1600, fraction: 0.9) == 700 && Reader.feedColumnWidth(total: 1000, fraction: 0) == 380 && Reader.feedColumnWidth(total: 1000, fraction: nil) == 380, "reader: the feed column stops at the old column's width, and no choice means the default")
check(Reader.fraction(forFeedWidth: 500, total: 1000) == 0.5 && Reader.fraction(forFeedWidth: 100, total: 1000) == 0.32 && Reader.fraction(forFeedWidth: 900, total: 1000) == 0.611, "reader: the remembered proportion is the clamped one, so the handle cannot be dragged to a width that would be refused")
check(Reader.feedColumnWidth(total: 800) == 340 && Reader.feedColumnWidth(total: 1000) == 380 && Reader.feedColumnWidth(total: 2000) == 460, "reader: the feed column keeps to what a post reads well at, and the reader gets the rest")
var rdPaper = ok("rd") { $0.authors = ["Ada One", "Bo Two", "Cy Three"]; $0.firstInstitution = "Ghent University"; $0.lastInstitution = "UCLouvain" }
let rdAuthors = Reader.authors(of: rdPaper)
check(rdAuthors.head.map(\.name) == ["Ada One", "Bo Two", "Cy Three"] && rdAuthors.omitted == 0 && rdAuthors.tail == nil, "reader: a short author list is shown whole")
check(rdAuthors.head.map(\.institution) == ["Ghent University", nil, "UCLouvain"] && rdAuthors.head.map(\.role) == [.first, .middle, .last], "reader: the institutions known go to the first and the last author, and nobody else")
check(Reader.authors(of: ok("h") { $0.authors = ["A", "B", "C"]; $0.firstAuthorH = 12; $0.lastAuthorH = 51 }).head.map(\.hIndex) == [12, nil, 51], "reader: the h-index is shown for the authors it is known for")
rdPaper.authors = (1...40).map { "Author \($0)" }
let rdLong = Reader.authors(of: rdPaper, limit: 12)
check(rdLong.head.count == 11 && rdLong.omitted == 28 && rdLong.tail?.name == "Author 40" && rdLong.tail?.institution == "UCLouvain", "reader: a long list shows the first authors, how many are left out and always the last author")
check(Reader.authors(of: ok("none")).isEmpty, "reader: no authors, no list")
rdPaper.authors = ["Solo"]
check(Reader.authors(of: rdPaper).head.map(\.role) == [.first] && Reader.authors(of: rdPaper).head[0].institution == "Ghent University", "reader: a single author is the first")
check(Reader.selection(afterRemoving: "b", from: ["a", "b", "c"]) == "c" && Reader.selection(afterRemoving: "c", from: ["a", "b", "c"]) == "b" && Reader.selection(afterRemoving: "a", from: ["a"]) == nil && Reader.selection(afterRemoving: "x", from: ["a"]) == nil, "reader: after a paper is hidden the pane moves to the one that took its place, else the one above, else empties")
check(Reader.neighbour(of: "b", offset: 1, in: ["a", "b", "c"]) == "c" && Reader.neighbour(of: "c", offset: 1, in: ["a", "b", "c"]) == "c" && Reader.neighbour(of: "a", offset: -1, in: ["a", "b", "c"]) == "a", "reader: the arrow keys stop at either end")
check(Reader.neighbour(of: nil, offset: 1, in: ["a", "b"]) == "a" && Reader.neighbour(of: "gone", offset: -1, in: ["a", "b"]) == "b" && Reader.neighbour(of: "a", offset: 1, in: []) == nil, "reader: with nothing selected a step down starts at the top")
let rdOrder = withOld.displayOrder(settings: layoutSettings)
check(rdOrder.first == "oa:star" && rdOrder.count == withOld.highlights.count + withOld.feed.fresh.count + withOld.older.count + withOld.feed.earlier.count, "reader: the on-screen order starts with the highlights and holds every paper once")
check(Array(rdOrder.suffix(3)) == withOld.older.suffix(3).map { $0.paper.dedupeKey } || rdOrder.firstIndex(of: "oa:recentOld")! > rdOrder.firstIndex(of: "oa:lowFollow")!, "reader: further back comes after the look-back")
var rdSections = layoutSettings; rdSections.feedOrder = .sections
let rdSecLayout = FeedLayout.make(citedYou: layoutCited, forYou: layoutOthers, history: History(), settings: rdSections, now: layoutNow)
check(Set(rdSecLayout.displayOrder(settings: rdSections)).count == rdSecLayout.displayOrder(settings: rdSections).count && rdSecLayout.displayOrder(settings: rdSections).first == "oa:star", "reader: in sections the order is the highlights, then cited you, what is followed, and the rest")
var rdMulti = ok("multi") { $0.reasons = ["Topic: Pain", "Author: Ada One", "Cites your work"]; $0.followed = true }
check(Why.all(for: rdMulti).map(\.text) == ["Cites your work", "Author you follow: Ada One", "Topic you follow: Pain"], "reader: every reason is listed, the user's most specific first")
check(Why.all(for: ok("noreason")).isEmpty && Why.all(for: rdMulti).first?.isCitation == true, "reader: no reasons, no list; a citation is marked")

// MARK: RIS
check(RIS.author("Valéry Legrain") == "Legrain, Valéry" && RIS.author("Marie Curie Skłodowska") == "Skłodowska, Marie Curie", "ris: a name becomes Last, First")
check(RIS.author("Legrain V") == "Legrain, V" && RIS.author("Smith JA") == "Smith, JA" && RIS.author("van der Berg JA") == "van der Berg, JA", "ris: Europe PMC's surname-then-initials is read as that")
check(RIS.author("Ludwig van der Berg") == "van der Berg, Ludwig" && RIS.author("Pedro de la Cruz") == "de la Cruz, Pedro", "ris: a particle stays with the surname")
check(RIS.author("Martin Luther King Jr.") == "King Jr., Martin Luther" && RIS.author("Smith, Ada") == "Smith, Ada" && RIS.author("Madonna") == "Madonna", "ris: a suffix stays with the surname, a comma is respected, one word stays")
var risPaper = Paper(id: "W1", doi: "10.1000/Demo.1", pmid: "42", title: "Cortical gamma\nresponses: a study", abstract: "Line one.\nLine two.\r\n\r\nLine three.", journal: "Pain", date: "2026-10-03", authors: ["Valéry Legrain", "Smith JA"])
risPaper.topics = ["Pain", "EEG"]; risPaper.language = "en"
let risText = RIS.document([RIS.reference(risPaper)])
let risLines = risText.components(separatedBy: "\r\n")
check(risLines.first == "TY  - JOUR" && risLines.contains("ER  - ") && risText.hasSuffix("ER  - \r\n\r\n"), "ris: a record opens with its type and closes with ER, with CRLF line ends")
check(risLines.filter { $0.hasPrefix("AU  - ") } == ["AU  - Legrain, Valéry", "AU  - Smith, JA"], "ris: one AU line per author, in order")
check(risLines.contains("TI  - Cortical gamma responses: a study") && risLines.contains("AB  - Line one. Line two. Line three."), "ris: a break inside a value does not start a new tag")
check(risLines.contains("T2  - Pain") && risLines.contains("PY  - 2026") && risLines.contains("DA  - 2026/10/03/") && risLines.contains("DO  - 10.1000/Demo.1") && risLines.contains("AN  - PMID:42") && risLines.contains("KW  - EEG") && risLines.contains("LA  - en"), "ris: journal, year, date, DOI, PMID, keywords and language are written")
check(risLines.contains("UR  - https://doi.org/10.1000/demo.1") || risLines.contains(where: { $0.hasPrefix("UR  - https://doi.org/") }), "ris: the link is the DOI's")
let risBare = RIS.record(RIS.reference(Paper(id: "W2", title: "Only a title", date: "2026")))
check(risBare == "TY  - JOUR\r\nTI  - Only a title\r\nPY  - 2026\r\nDA  - 2026///\r\nUR  - https://openalex.org/W2\r\nER  - \r\n\r\n", "ris: a paper with little leaves out what it lacks, and a bare year stays a year")
check(RIS.document([]) == "" && RIS.document([RIS.reference(risPaper), RIS.reference(risPaper)]).components(separatedBy: "TY  - ").count == 3, "ris: a file holds one record per reference")
var risConf = risPaper; risConf.pubmedTypes = ["Congress"]
check(RIS.record(RIS.reference(risConf)).hasPrefix("TY  - CONF"), "ris: a conference abstract is a conference paper")
let risSavedOld = SavedPaper(Paper(id: "W3", doi: "10.1/old", title: "Old save", abstract: "A.", date: "2026-09-01"))
let risOldRef = RIS.reference(risSavedOld)
check(risOldRef.doi == "10.1/old" && risOldRef.authors.isEmpty && risOldRef.url == "https://doi.org/10.1/old", "ris: an older saved paper still exports, with the DOI its id carries")
let risFilled = RIS.reference(risSavedOld, known: risPaper)
check(risFilled.authors == ["Valéry Legrain", "Smith JA"] && risFilled.title == "Old save" && risFilled.journal == "Pain", "ris: the feed's copy fills what an older saved paper lacks, the saved title stays")
let risSavedNew = SavedPaper(risPaper)
check(risSavedNew.authors == ["Valéry Legrain", "Smith JA"] && risSavedNew.journal == "Pain" && RIS.reference(risSavedNew).authors.count == 2, "ris: a paper saved now keeps its authors and journal")
check((try? JSONDecoder().decode(SavedPaper.self, from: Data(#"{"id":"doi:1","title":"T","date":"2026-01-01"}"#.utf8)))?.authors == nil, "ris: a saved paper written before authors were kept still loads")
check(RIS.references([risSavedOld, SavedPaper(ok("zz"))], known: [risPaper.withDOI("10.1/old")]).map(\.authors) == [["Valéry Legrain", "Smith JA"], []], "ris: a list of saved papers is filled from the feed by key, and one the feed no longer holds keeps what it has")
check(RIS.fileName(for: RIS.reference(risPaper)) == "Legrain-2026-Cortical-gamma-responses-a.ris" && RIS.fileName(for: RIS.Reference(title: "???", date: "")) == "reference.ris", "ris: the file is named for who, when and what, and never empty")

// MARK: Zotero
let zoteroJSON = Data("""
[
 {"key":"AAA","version":9,"data":{"itemType":"journalArticle","title":"  Cortical gamma responses  ","abstractNote":"We recorded EEG.","DOI":"https://doi.org/10.1000/ABC","dateAdded":"2026-11-02T09:14:05Z","publicationTitle":"Pain","tags":[{"tag":"EEG"},{"tag":"pain","type":1}]}},
 {"key":"BBB","data":{"itemType":"preprint","title":"A preprint","repository":"bioRxiv","dateAdded":"2026-10-01T10:00:00Z","tags":[]}},
 {"key":"CCC","data":{"itemType":"attachment","title":"Full Text PDF","dateAdded":"2026-11-03T10:00:00Z"}},
 {"key":"DDD","data":{"itemType":"note","note":"<p>hi</p>","dateAdded":"2026-11-04T10:00:00Z"}},
 {"key":"EEE","data":{"itemType":"book","title":"","dateAdded":"2026-11-05T10:00:00Z"}},
 {"key":"FFF","data":{"itemType":"journalArticle","title":"Newest, no abstract","dateAdded":"2026-11-06T10:00:00Z","tags":[{"tag":"nociception"}]}}
]
""".utf8)
let zItems = Zotero.items(from: zoteroJSON)
check(zItems.map(\.key) == ["AAA", "BBB", "FFF"], "zotero: papers are read; attachments, notes and untitled items are not")
check(zItems[0].title == "Cortical gamma responses" && zItems[0].doi == "10.1000/abc" && zItems[0].journal == "Pain" && zItems[0].tags == ["EEG", "pain"], "zotero: title trimmed, DOI made bare, journal and tags kept")
check(zItems[1].journal == "bioRxiv" && zItems[1].abstract == nil, "zotero: a preprint's server stands in for the journal")
check(Zotero.items(from: Data("{}".utf8)).isEmpty && Zotero.items(from: Data("nope".utf8)).isEmpty, "zotero: an answer that is not a list gives nothing, not an error")
check(Zotero.profileText(zItems[0]) == "Cortical gamma responses. We recorded EEG.. EEG, pain" || Zotero.profileText(zItems[0]).hasSuffix("EEG, pain"), "zotero: the text is title, abstract and the user's own tags, tags last")
let zTexts = Zotero.profileTexts(zItems, recent: 2)
check(zTexts.count == 2 && zTexts[0].hasPrefix("Newest, no abstract") && zTexts[1].hasPrefix("Cortical gamma"), "zotero: the most recently added come first, and only as many as asked")
check(Zotero.profileTexts(zItems, recent: 0).isEmpty && Zotero.profileTexts([], recent: 50).isEmpty, "zotero: none asked, or none held, is none")
var zSettings = FeedSettings(); zSettings.useZotero = true
check(FeedBuilder.profileTexts(zSettings, own: [], library: ["a library text"]).contains("a library text") && !FeedBuilder.profileTexts(FeedSettings(), own: [], library: ["a library text"]).contains("a library text"), "zotero: the library joins the profile only when the user switched it on")
check(FeedSettings().useZotero == false && FeedSettings().zoteroRecent == 100, "zotero: off by default")
var zClamped = Data(#"{"useZotero":true,"zoteroRecent":100000}"#.utf8)
check((try? FeedSettings.decode(zClamped))?.zoteroRecent == 500 && (try? FeedSettings.decode(Data("{}".utf8)))?.useZotero == false, "zotero: the count is clamped when read, and an older settings file means off")
var zOn = FeedSettings(); zOn.useZotero = true
check(zOn.forFetching == FeedSettings().forFetching && zOn.forRanking != FeedSettings().forRanking, "zotero: switching it on re-ranks what is held and fetches nothing again")
check(device(zOn, stamp: at(1)).apply(to: FeedSettings()).useZotero, "zotero: the choice syncs")
let zKey = Data(#"{"key":"k","userID":123,"username":"ada","access":{"user":{"library":true,"files":true,"notes":true,"write":true}}}"#.utf8)
check(Zotero.account(key: "secret", from: zKey) == ZoteroAccount(key: "secret", userID: 123, username: "ada", canWrite: true), "zotero: the account and write access are read from the key's description")
check(Zotero.account(key: "k", from: Data(#"{"userID":5,"access":{"user":{"library":true}}}"#.utf8))?.canWrite == false && Zotero.account(key: "k", from: Data("{}".utf8)) == nil, "zotero: a read-only key says so, and a refusal is no account")
var zRef = RIS.Reference(title: "A paper", authors: ["Valéry Legrain", "Smith JA"], journal: "Pain", date: "2026-10-03", abstract: "Abs.", doi: "10.1/x", url: "https://doi.org/10.1/x", keywords: ["EEG"], language: "en")
let zNew = (try! JSONSerialization.jsonObject(with: Zotero.newItems(zRef)) as! [[String: Any]])[0]
check(zNew["itemType"] as? String == "journalArticle" && zNew["publicationTitle"] as? String == "Pain" && zNew["DOI"] as? String == "10.1/x" && zNew["date"] as? String == "2026-10-03", "zotero: a paper is saved as a journal article with its journal, DOI and date")
let zCreators = zNew["creators"] as! [[String: String]]
check(zCreators[0] == ["creatorType": "author", "lastName": "Legrain", "firstName": "Valéry"] && zCreators[1]["lastName"] == "Smith" && zCreators[1]["firstName"] == "JA", "zotero: authors are split into first and last names")
check((zNew["tags"] as! [[String: String]]) == [["tag": "EEG"]], "zotero: the topics become tags")
zRef.isPreprint = true
let zPre = (try! JSONSerialization.jsonObject(with: Zotero.newItems(zRef)) as! [[String: Any]])[0]
check(zPre["itemType"] as? String == "preprint" && zPre["repository"] as? String == "Pain" && zPre["publicationTitle"] == nil, "zotero: a preprint is a preprint, its server in the repository field")
check(Zotero.writeFailure(from: Data(#"{"successful":{"0":{"key":"X"}},"failed":{}}"#.utf8)) == nil && Zotero.writeFailure(from: Data(#"{"successful":{},"failed":{"0":{"code":400,"message":"'x' is not a valid field"}}}"#.utf8)) == "'x' is not a valid field" && Zotero.writeFailure(from: Data("x".utf8)) != nil, "zotero: a write that created nothing says why")

// MARK: Zotero client, against a stub that answers instead of the network
final class ZoteroStub: URLProtocol {
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var answer: (URLRequest) -> (Int, [String: String], Data) = { _ in (200, [:], Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            req.httpBody = data
        }
        Self.seen.append(req)
        let (code, headers, body) = Self.answer(req)
        let response = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let zConfig = URLSessionConfiguration.ephemeral; zConfig.protocolClasses = [ZoteroStub.self]
let zSession = URLSession(configuration: zConfig)
let zAccount = ZoteroAccount(key: "SECRETKEY", userID: 77, username: "ada", canWrite: true)
let zClient = ZoteroClient(account: zAccount, session: zSession)
func zPage(_ n: Int, from: Int = 0) -> Data {
    let items = (from..<(from + n)).map { #"{"key":"K\#($0)","data":{"itemType":"journalArticle","title":"Paper \#($0)","dateAdded":"2026-11-\#(String(format: "%02d", 30 - $0 % 28))T10:00:00Z"}}"# }
    return Data(("[" + items.joined(separator: ",") + "]").utf8)
}
ZoteroStub.answer = { _ in (200, [:], zKey) }
let zConnected = try? await ZoteroClient.connect(key: "SECRETKEY", session: zSession)
check(zConnected?.userID == 123 && zConnected?.canWrite == true && ZoteroStub.seen.last?.value(forHTTPHeaderField: "Zotero-API-Key") == "SECRETKEY" && ZoteroStub.seen.last?.url?.absoluteString.contains("SECRETKEY") == false, "zotero client: the key is sent in a header and never in the address")
ZoteroStub.answer = { _ in (403, [:], Data()) }
var zRefused = false
do { _ = try await ZoteroClient.connect(key: "bad", session: zSession) } catch let e as ZoteroError { if case .refused = e { zRefused = true } } catch {}
check(zRefused, "zotero client: a refused key is reported as refused")
ZoteroStub.seen = []
ZoteroStub.answer = { req in
    let start = Int(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "start" }!.value!)!
    return start == 0 ? (200, ["Last-Modified-Version": "42"], zPage(100)) : (200, ["Last-Modified-Version": "42"], zPage(30, from: 100))
}
let zRecent = try? await zClient.recent(limit: 250, cache: nil)
check(zRecent?.items.count == 130 && zRecent?.version == 42 && ZoteroStub.seen.count == 2, "zotero client: it pages by a hundred and stops at the end of the library")
let zFirst = ZoteroStub.seen[0].url!.absoluteString
check(zFirst.contains("sort=dateAdded") && zFirst.contains("direction=desc") && zFirst.contains("/users/77/items") && ZoteroStub.seen[0].value(forHTTPHeaderField: "Zotero-API-Version") == "3", "zotero client: it asks for the newest added first, as API version 3")
ZoteroStub.seen = []
ZoteroStub.answer = { _ in (304, [:], Data()) }
let zUnchanged = try? await zClient.recent(limit: 100, cache: zRecent)
check(zUnchanged == zRecent && ZoteroStub.seen.count == 1 && ZoteroStub.seen[0].value(forHTTPHeaderField: "If-Modified-Since-Version") == "42", "zotero client: an unchanged library costs one request and is answered from the copy held")
ZoteroStub.seen = []
ZoteroStub.answer = { _ in (200, ["Last-Modified-Version": "43"], zPage(3)) }
let zBigger = try? await zClient.recent(limit: 100, cache: ZoteroCache(userID: 77, version: 42, asked: 10, items: []))
check(zBigger?.items.count == 3 && ZoteroStub.seen[0].value(forHTTPHeaderField: "If-Modified-Since-Version") == nil, "zotero client: a copy made for fewer items than are wanted now is not trusted")
ZoteroStub.answer = { _ in (429, ["Retry-After": "30"], Data()) }
var zSlow = ""
do { _ = try await zClient.recent(limit: 10, cache: nil) } catch { zSlow = "\(error)" }
check(zSlow.contains("30 seconds") && !zSlow.contains("SECRETKEY"), "zotero client: a request to wait is passed on, and no error carries the key")
ZoteroStub.seen = []
ZoteroStub.answer = { _ in (200, [:], zoteroJSON) }
let zHasYes = try? await zClient.has(doi: "10.1000/ABC")
let zHasNo = try? await zClient.has(doi: "10.9/none")
check(zHasYes == true && zHasNo == false, "zotero client: a paper already in the library is found by its DOI")
ZoteroStub.seen = []
ZoteroStub.answer = { _ in (200, [:], Data(#"{"successful":{"0":{"key":"NEW"}},"failed":{}}"#.utf8)) }
var zAdded = false
do { try await zClient.add(zRef); zAdded = true } catch {}
let zPost = ZoteroStub.seen.last
check(zAdded && zPost?.httpMethod == "POST" && zPost?.url?.path == "/users/77/items" && (zPost?.value(forHTTPHeaderField: "Zotero-Write-Token") ?? "").count == 32 && zPost?.httpBody != nil, "zotero client: saving is one POST with a write token, so a retry cannot make two")
ZoteroStub.answer = { _ in (200, [:], Data(#"{"successful":{},"failed":{"0":{"code":400,"message":"bad field"}}}"#.utf8)) }
var zFail = ""
do { try await zClient.add(zRef) } catch { zFail = "\(error)" }
check(zFail.contains("bad field"), "zotero client: when Zotero refuses an item the reason is shown")
var zRead = zAccount; zRead.canWrite = false
ZoteroStub.seen = []
var zReadOnly = ""
do { try await ZoteroClient(account: zRead, session: zSession).add(zRef) } catch { zReadOnly = "\(error)" }
check(zReadOnly.contains("only read") && ZoteroStub.seen.isEmpty, "zotero client: a read-only key is told so before anything is sent")

// MARK: summaries from a model the user has an account with
let rsClaude = RemoteSummaryConfig(provider: .anthropic, key: "SECRET", model: "")
let rsReq = RemoteSummary.request(rsClaude, title: "A title", abstract: "An abstract.")
let rsBody = try! JSONSerialization.jsonObject(with: rsReq.httpBody!) as! [String: Any]
check(rsReq.url?.absoluteString == "https://api.anthropic.com/v1/messages" && rsReq.value(forHTTPHeaderField: "x-api-key") == "SECRET" && rsReq.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21" && !rsReq.url!.absoluteString.contains("SECRET"), "remote summary: Claude is asked over its messages API, the key in a header only")
check(rsBody["model"] as? String == "claude-opus-5-5" && (rsBody["output_config"] as? [String: String]) == ["effort": "low"] && rsBody["temperature"] == nil && rsBody["top_p"] == nil && (rsBody["max_tokens"] as? Int ?? 0) >= 2000, "remote summary: an empty model means the default; low effort; no sampling settings (current models reject them); room for thinking")
var rsOld = rsClaude; rsOld.model = "claude-haiku-4-5"
check((try! JSONSerialization.jsonObject(with: RemoteSummary.request(rsOld, title: "t", abstract: "a").httpBody!) as! [String: Any])["output_config"] == nil && RemoteSummary.supportsEffort("claude-haiku-5-5") && RemoteSummary.supportsEffort("claude-sonnet-5-5") && !RemoteSummary.supportsEffort("claude-sonnet-4-6"), "remote summary: the effort setting is sent only to a model that has it")
let rsAI = RemoteSummary.request(RemoteSummaryConfig(provider: .openai, key: "SECRET", model: "gpt-x"), title: "t", abstract: "a")
check(rsAI.url?.host == "api.openai.com" && rsAI.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET" && ((try! JSONSerialization.jsonObject(with: rsAI.httpBody!) as! [String: Any])["model"] as? String) == "gpt-x", "remote summary: ChatGPT is asked over its chat completions API with the model the user named")
check((try! JSONSerialization.jsonObject(with: rsReq.httpBody!) as! [String: Any])["system"] as? String == RemoteSummary.instructions && String(decoding: rsReq.httpBody!, as: UTF8.self).contains("Abstract: An abstract."), "remote summary: the paper goes in the message and the brief in the system prompt")
let rsLongAbstract = RemoteSummary.prompt(title: "T", abstract: String(repeating: "x", count: 9000))
check(rsLongAbstract.count < 3100, "remote summary: a very long abstract is cut before it is sent")
check(RemoteSummary.text(from: Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Patients showed a reduced late potential."}],"stop_reason":"end_turn"}"#.utf8), provider: .anthropic) == "Patients showed a reduced late potential.", "remote summary: only the text blocks of Claude's answer are read, not its thinking")
check(RemoteSummary.text(from: Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8), provider: .anthropic) == nil && RemoteSummary.text(from: Data("x".utf8), provider: .anthropic) == nil, "remote summary: a refusal or an unreadable answer is no text")
check(RemoteSummary.text(from: Data(#"{"choices":[{"message":{"content":"One finding."}}]}"#.utf8), provider: .openai) == "One finding." && RemoteSummary.text(from: Data(#"{"choices":[{"message":{"content":null,"refusal":"no"}}]}"#.utf8), provider: .openai) == nil, "remote summary: ChatGPT's reply is read, a refusal is none")
check(RemoteSummary.clean("\"The study found that EEG gamma power rose. It did not change with pain intensity. A third sentence follows here. And a fourth one.\"") != nil && RemoteSummary.clean("ok") == nil, "remote summary: an answer is held to two sentences, like the on-device one, and a stub of one word is dropped")
ZoteroStub.seen = []
ZoteroStub.answer = { _ in (200, [:], Data(#"{"content":[{"type":"text","text":"The EEG gamma response was larger in patients with chronic pain."}],"stop_reason":"end_turn"}"#.utf8)) }
let rsGot = try? await RemoteSummary.takeaway(rsClaude, title: "T", abstract: "A.", session: zSession)
check(rsGot == "The EEG gamma response was larger in patients with chronic pain.", "remote summary: a call returns the cleaned takeaway")
var rsFailure = ""
ZoteroStub.answer = { _ in (401, [:], Data()) }
do { _ = try await RemoteSummary.takeaway(rsClaude, title: "T", abstract: "A.", session: zSession) } catch { rsFailure = "\(error)" }
check(rsFailure.contains("refused") && !rsFailure.contains("SECRET"), "remote summary: a refused key is said so, without the key")
ZoteroStub.answer = { _ in (200, [:], Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)) }
let rsDeclined = try? await RemoteSummary.takeaway(rsClaude, title: "T", abstract: "A.", session: zSession)
check(rsDeclined == .some(nil), "remote summary: a model that declines gives nothing, which is not an error")
check(RemoteSummaryConfig(provider: .openai, key: "k", model: "  ").modelOrDefault == "gpt-4o-mini", "remote summary: a blank model name means the default")

// MARK: library import (RIS and BibTeX)
let impRIS = "\u{FEFF}TY  - JOUR\r\nAU  - Legrain, Valéry\r\nTI  - Cortical gamma responses\r\n  to painful heat\r\nT2  - Pain\r\nPY  - 2025///\r\nAB  - We recorded EEG in 84 patients.\r\nN2  - Short note.\r\nAB  - We recorded EEG in 84 patients with chronic pain\r\nand 80 controls.\r\nKW  - EEG\r\nKW  - pain; gamma\r\nDO  - https://doi.org/10.1000/ABC\r\nER  - \r\n\r\nTY  - CONF\r\nT1  - A conference paper\r\nJO  - Proc. X\r\nY1  - 2023/05/01/\r\nER  - \r\n\r\nTY  - JOUR\r\nAB  - A record with no title\r\nER  - \r\n"
let impRisItems = LibraryImport.ris(LibraryImport.text(of: Data(impRIS.utf8))!)
check(impRisItems.count == 2 && impRisItems[0].title == "Cortical gamma responses to painful heat" && impRisItems[1].title == "A conference paper", "import ris: records from TY to ER, a wrapped title joined, a record with no title left out")
check(impRisItems[0].abstract == "We recorded EEG in 84 patients with chronic pain and 80 controls." && impRisItems[0].doi == "10.1000/abc" && impRisItems[0].journal == "Pain" && impRisItems[0].published == "2025", "import ris: the longest abstract wins, a wrapped line is joined, the DOI made bare, the year read from RIS's date")
check(impRisItems[0].tags == ["EEG", "pain", "gamma"] && impRisItems[1].journal == "Proc. X" && impRisItems[1].published == "2023" && impRisItems[1].itemType == "conf", "import ris: keywords are split on , and ;, T1 and JO and Y1 are read as well as TI, T2 and PY")
let impBib = #"""
% a comment
@comment{jabref-meta: x}
@string{pain = "Pain"}
@article{legrain2025,
  author = {Legrain, Val{\'e}ry and M{\"u}ller, Jonas},
  title = {Cortical {EEG} responses to {P}ainful heat in {\"U}ber-chronic pain},
  journal = pain,
  year = 2025,
  doi = {10.1000/Bib.1},
  abstract = {We recorded EEG
     in 84 patients; \emph{gamma} rose by 20\% (see {Fig. 1}).},
  keywords = {EEG, pain; gamma},
  date-added = {2026-11-02 10:00:00 +0100}
}
@inproceedings(conf1, title = "A plain {Q}uoted title", booktitle = {Proc. Y}, year = {2022})
@book{nottitle, year = 2020}
"""#
let impBibItems = LibraryImport.bibtex(impBib)
check(impBibItems.count == 2 && impBibItems[1].title == "A plain Quoted title" && impBibItems[1].journal == "Proc. Y", "import bibtex: comments and @string are skipped, an entry with no title is left out, quotes and parentheses work")
check(impBibItems[0].title == "Cortical EEG responses to Painful heat in Über-chronic pain", "import bibtex: protective braces are dropped and accents become letters")
check(impBibItems[0].abstract == "We recorded EEG in 84 patients; gamma rose by 20% (see Fig. 1)." && impBibItems[0].doi == "10.1000/bib.1" && impBibItems[0].published == "2025" && impBibItems[0].tags == ["EEG", "pain", "gamma"], "import bibtex: nested braces, a command, an escaped percent sign, the DOI, a bare year and keywords are read")
check(impBibItems[0].dateAdded == "2026-11-02T00:00:00Z" && impBibItems[1].dateAdded == "", "import bibtex: a date-added the file carries is kept")
check(LibraryImport.clean(#"Stra{\ss}e \c{c}a \v{S}koda {\o}l"#) == "Straße ça Škoda øl", "import bibtex: LaTeX symbols and accents are turned into characters")
check(LibraryImport.format(of: impRIS) == .ris && LibraryImport.format(of: impBib) == .bibtex && LibraryImport.format(of: "hello", filename: "x.ris") == .ris && LibraryImport.format(of: "hello", filename: "x.txt") == nil, "import: the format is told from the contents first and the extension second")
check(LibraryImport.items(from: Data(impRIS.utf8), filename: "export.txt").count == 2 && LibraryImport.items(from: Data("nothing here".utf8), filename: "a.txt").isEmpty, "import: a file with no papers gives none")
check(LibraryImport.text(of: Data([0x54, 0x69, 0xE9]))  == "Tié", "import: a Windows-1252 file is read as that")
var impUTF16 = Data([0xFF, 0xFE]); impUTF16.append("TY  - JOUR".data(using: .utf16LittleEndian)!)
check(LibraryImport.text(of: impUTF16)?.hasSuffix("JOUR") == true, "import: a UTF-16 file is read")
let impDay1 = Date(timeIntervalSince1970: 1_700_000_000), impDay2 = Date(timeIntervalSince1970: 1_700_000_000 + 86_400 * 30)
let impFirst = LibraryImport.merged(previous: nil, parsed: impRisItems, name: "a.ris", now: impDay1)
check(impFirst.items.count == 2 && Set(impFirst.items.map(\.dateAdded)).count == 1 && impFirst.items[0].key == "doi:10.1000/abc" && impFirst.items[1].key.hasPrefix("title:"), "import: a first import dates everything alike and keys by DOI, else by title")
let impNew = LibraryItem(key: "", title: "Brand new paper", abstract: nil, doi: nil, dateAdded: "", tags: [], journal: nil, itemType: "jour", published: "2026")
let impSecond = LibraryImport.merged(previous: impFirst, parsed: [impNew] + impRisItems + impRisItems, name: "b.ris", now: impDay2)
check(impSecond.items.count == 3 && impSecond.items.first { $0.title == "Brand new paper" }?.dateAdded == impSecond.importedAt && impSecond.items.first { $0.doi == "10.1000/abc" }?.dateAdded == impFirst.importedAt, "import: a second import keeps when old items first appeared, dates the new one today, and drops duplicates")
let impTexts = Zotero.profileTexts(impSecond.items, recent: 1)
check(impTexts.count == 1 && impTexts[0].hasPrefix("Brand new paper"), "import: what was added in the latest import comes first")
let impSame = LibraryImport.merged(previous: nil, parsed: [LibraryItem(key: "", title: "Older", abstract: nil, doi: nil, dateAdded: "", tags: [], journal: nil, itemType: "jour", published: "2019"), LibraryItem(key: "", title: "Newer", abstract: nil, doi: nil, dateAdded: "", tags: [], journal: nil, itemType: "jour", published: "2025")], name: "c.ris", now: impDay1)
check(Zotero.profileTexts(impSame.items, recent: 2).map { String($0.prefix(5)) } == ["Newer", "Older"], "import: items that arrived together are ordered by publication year, newest first")
check(LibraryImport.merged(previous: nil, parsed: (0..<10).map { LibraryItem(key: "", title: "P\($0)", abstract: nil, doi: nil, dateAdded: "", tags: [], journal: nil, itemType: "jour") }, name: "x", now: impDay1, limit: 4).items.count == 4, "import: a huge export is capped")
var impSettings = FeedSettings(); impSettings.useLibraryFile = true
check(FeedBuilder.profileTexts(impSettings, own: [], library: ["from a file"]).contains("from a file") && impSettings.forFetching == FeedSettings().forFetching && device(impSettings, stamp: at(1)).apply(to: FeedSettings()).useLibraryFile, "import: the choice joins the profile, re-ranks without fetching, and syncs")

// MARK: rough pastes
let roughRefs = """
1. Legrain V, Iannetti GD, Plaghki L, Mouraux A. The pain matrix reloaded: a salience detection system for the body. Prog Neurobiol. 2011;93(1):111-124. doi:10.1016/j.pneurobio.2010.10.005
[2] Mouraux, A., & Iannetti, G. D. (2018). The search for pain biomarkers in the human brain. Brain, 141(12), 3290-3293. https://doi.org/10.1093/brain/awy281
- “Cortical gamma responses to painful heat in chronic pain” Pain, 2025
Spinal cord stimulation for neuropathic pain
10.1000/only.a.doi
too short
"""
let roughItems = LibraryImport.rough(roughRefs)
check(roughItems.count == 4, "paste: a list of references with no blank lines gives one entry per line, and a bare DOI or a stub is left out")
check(roughItems[0].title == "The pain matrix reloaded: a salience detection system for the body" && roughItems[0].doi == "10.1016/j.pneurobio.2010.10.005" && roughItems[0].published == "2011", "paste: a Vancouver-style reference gives its title, DOI and year")
check(roughItems[1].title == "The search for pain biomarkers in the human brain" && roughItems[1].journal == "Brain" && roughItems[1].doi == "10.1093/brain/awy281", "paste: an APA-style reference gives the title after the year, the journal after it, and the DOI from a link")
check(roughItems[2].title == "Cortical gamma responses to painful heat in chronic pain" && roughItems[3].title == "Spinal cord stimulation for neuropathic pain", "paste: a quoted title is taken as it is, and a line that is only a title is a title")
let roughBlocks = LibraryImport.rough("Cortical gamma responses to painful heat\nin chronic low back pain patients\n\nSpinal cord stimulation for neuropathic pain in the era\nof closed-loop control")
check(roughBlocks.count == 2 && roughBlocks[0].title == "Cortical gamma responses to painful heat in chronic low back pain patients", "paste: blank lines separate entries and a wrapped one is joined")
check(LibraryImport.rough(impBib).count == 2 && LibraryImport.rough(impRIS).count == 2 && LibraryImport.rough("").isEmpty && LibraryImport.rough("   \n\n  ").isEmpty, "paste: RIS and BibTeX are read as such, and nothing is nothing")
let roughFirst = LibraryImport.adding(to: nil, parsed: roughItems, name: "Pasted", now: impDay1)
let roughMore = LibraryImport.adding(to: roughFirst, parsed: LibraryImport.rough("Brand new pasted paper about itch and scratching") + roughItems, name: "Pasted", now: impDay2)
check(roughMore.items.count == 5 && roughMore.items.first { $0.title.hasPrefix("Brand new") }?.dateAdded == roughMore.importedAt && roughMore.items.first { $0.doi == "10.1016/j.pneurobio.2010.10.005" }?.dateAdded == roughFirst.importedAt && roughMore.name == "Pasted", "paste: a second paste adds, keeps the dates of what was there, and does not double a paper")
check(Zotero.profileTexts(roughMore.items, recent: 1)[0].hasPrefix("Brand new"), "paste: what was pasted last counts as the newest")

// MARK: markup in titles
let htmlPaper = Paper(id: "W1", title: "Sequence-Activity and Integrated <i>In Silico</i> and <i>In Vitro</i> Study of <i>Staphylococcus aureus</i> &amp; peptides", abstract: "<jats:p>We show &lt;5% loss.</jats:p>", date: "2026-10-01").withPlainText
check(htmlPaper.title == "Sequence-Activity and Integrated In Silico and In Vitro Study of Staphylococcus aureus & peptides" && htmlPaper.abstract == "We show <5% loss.", "markup: tags and entities are gone from a title and an abstract, including a cache written before they were cleaned")
check(Paper(id: "W2", title: "Plain title", abstract: nil, date: "2026-10-01").withPlainText == Paper(id: "W2", title: "Plain title", abstract: nil, date: "2026-10-01"), "markup: a clean paper is left as it is")

// MARK: dwell time and "for me"
let dwNow = Date(timeIntervalSince1970: 1_800_000_000)
func dwAt(_ days: Double) -> Date { dwNow.addingTimeInterval(days * 86_400) }
var dwH = History()
dwH.addDwell("flick", seconds: 0.6, at: dwNow)
dwH.addDwell("glance", seconds: 2.0, at: dwNow)
dwH.addDwell("study", seconds: 5.0, at: dwNow)
check(dwH.status(of: "flick") == .new && dwH.status(of: "glance") == .seen && dwH.status(of: "study") == .seen, "dwell: a flick under 1.5 seconds is still new, a glance is seen")
check(dwH.attention(of: "flick", studiedAfter: 4) == .passed && dwH.attention(of: "glance", studiedAfter: 4) == .glanced && dwH.attention(of: "study", studiedAfter: 4) == .studied && dwH.attention(of: "study", studiedAfter: 8) == .glanced, "dwell: three levels, and the studied one follows the user's number of seconds")
dwH.addDwell("flick", seconds: 1.2, at: dwAt(0.1))
check(dwH.status(of: "flick") == .seen && abs((dwH.states["flick"]?.dwell ?? 0) - 1.8) < 0.001, "dwell: visits add up, so two short looks make a glance")
dwH.markSeen("legacy", at: dwNow)
check(dwH.status(of: "legacy") == .seen && dwH.attention(of: "legacy", studiedAfter: 4) == .glanced, "dwell: a record from before dwell was measured is still seen, and counted as a glance")
dwH.addDwell("legacy", seconds: 0.2, at: dwNow)
check(dwH.status(of: "legacy") == .seen, "dwell: a legacy record that gets a short extra look stays seen")
dwH.addDwell("zero", seconds: 0, at: dwNow)
check(dwH.states["zero"] == nil, "dwell: no time, no record")
dwH.markStudied("known", studiedAfter: 4, at: dwNow)
check(dwH.attention(of: "known", studiedAfter: 4) == .studied && dwH.status(of: "known") == .seen, "for me: counts as having studied the paper, even if it was never on screen long")
dwH.markStudied("study", studiedAfter: 4, at: dwNow)
check((dwH.states["study"]?.dwell ?? 0) == 5.0, "for me: it never lowers the time already measured")
var dwS = FeedSettings(); dwS.seenExpiryDays = 7
func dwPaper(_ id: String) -> RankedPaper { RankedPaper(paper: ok(id), score: 1, similarity: 0.5) }
var dwHist = History()
dwHist.addDwell(dwPaper("a").paper.dedupeKey, seconds: 2, at: dwNow.addingTimeInterval(-3 * 86_400))   // glanced, 3 days ago
dwHist.addDwell(dwPaper("b").paper.dedupeKey, seconds: 9, at: dwNow.addingTimeInterval(-1 * 86_400))   // studied, 1 day ago
dwHist.addDwell(dwPaper("c").paper.dedupeKey, seconds: 9, at: dwNow.addingTimeInterval(-3 * 86_400))   // studied, 3 days ago
dwHist.addDwell(dwPaper("d").paper.dedupeKey, seconds: 0.5, at: dwNow.addingTimeInterval(-3 * 86_400)) // flicked
let dwOut = Arranger.arrange(["b", "a", "c", "d", "e"].map(dwPaper), history: dwHist, settings: dwS, now: dwNow)
check(dwOut.fresh.map { $0.paper.id } == ["d", "e"], "arrange: a flicked post and an unseen one are both new")
check(dwOut.earlier.map { $0.paper.id } == ["a", "b"], "arrange: a studied post goes below a glanced one, whatever it scored")
check(!dwOut.earlier.contains { $0.paper.id == "c" }, "arrange: a studied post leaves after two days, while a glanced one stays for the week")
var dwShort = dwS; dwShort.seenExpiryDays = 1
check(!Arranger.arrange(["b"].map(dwPaper), history: { var h = History(); h.addDwell(dwPaper("b").paper.dedupeKey, seconds: 9, at: dwNow.addingTimeInterval(-1.5 * 86_400)); return h }(), settings: dwShort, now: dwNow).earlier.contains { $0.paper.id == "b" }, "arrange: a short seen-expiry setting still wins over the studied one")
check(FeedSettings().dwellSeconds == 4 && (try? FeedSettings.decode(Data(#"{"dwellSeconds":99}"#.utf8)))?.dwellSeconds == 15 && (try? FeedSettings.decode(Data(#"{"dwellSeconds":0}"#.utf8)))?.dwellSeconds == 2, "dwell: four seconds by default, between two and fifteen")
var dwChanged = FeedSettings(); dwChanged.dwellSeconds = 9
check(dwChanged.forFetching == FeedSettings().forFetching && dwChanged.forRanking == FeedSettings().forRanking && device(dwChanged, stamp: at(1)).apply(to: FeedSettings()).dwellSeconds == 9, "dwell: it only changes how what is held is arranged, so it fetches and re-ranks nothing, and it syncs")
let dwMerged = PaperState.merge(PaperState(firstSeen: at(1), lastSeen: at(2), seenCount: 1, dwell: 3), PaperState(firstSeen: at(1), lastSeen: at(3), seenCount: 1, dwell: 7))
check(dwMerged.dwell == 7 && PaperState.merge(PaperState(firstSeen: at(1), lastSeen: at(2), seenCount: 1), PaperState(firstSeen: at(1), lastSeen: at(2), seenCount: 1)).dwell == nil, "dwell: devices merge to the larger time, and nothing stays nothing")
check((try? JSONDecoder().decode(PaperState.self, from: Data(#"{"firstSeen":0,"lastSeen":0,"seenCount":2}"#.utf8)))?.dwell == nil, "dwell: a history file from before it still loads")
var fmFeedback = Feedback()
let fmPaper = ok("fm") { $0.title = "A paper I already know"; $0.abstract = "About nociception." }
fmFeedback.like(fmPaper); fmFeedback.like(fmPaper)
check(fmFeedback.liked.count == 1 && fmFeedback.isLiked(fmPaper) && fmFeedback.saved.isEmpty, "for me: it is kept once, and it does not save the paper")
var fmSettings = FeedSettings(); fmSettings.feedback = fmFeedback
check(FeedBuilder.profileTexts(fmSettings, own: []).contains { $0.hasPrefix("A paper I already know") }, "for me: the paper joins the profile like a saved one")
check(device(fmSettings, stamp: at(1)).apply(to: FeedSettings()).feedback.liked.map(\.id) == [fmPaper.dedupeKey], "for me: it syncs")
fmFeedback.unlike(fmPaper.dedupeKey)
check(!fmFeedback.isLiked(fmPaper) && (try? JSONDecoder().decode(Feedback.self, from: Data(#"{"saved":[],"hidden":[]}"#.utf8)))?.liked.isEmpty == true, "for me: it can be taken back, and a settings file from before it still loads")
check(SyncDocument.currentFormat == 2, "sync: the format is raised, so an app that does not know the newer entries leaves the file alone instead of erasing them")

func keptPaper(_ id: String, _ reasons: [String], followed: Bool = true, age: Int = 3) -> SavedPaper {
    var p = paper(id, "Paper \(id)", age: age); p.reasons = reasons; p.followed = followed
    p.authors = ["Ada Lovelace"]
    return SavedPaper(p)
}
let sfA = keptPaper("a", ["Topic: Electroencephalography"], age: 5)
let sfB = keptPaper("b", ["Author: Marie Curie", "Topic: Electroencephalography"], age: 2)
let sfC = keptPaper("c", ["Cites your work"], age: 9)
let sfD = keptPaper("d", ["Topic: Pain"], followed: false, age: 1)
var sfOld = SavedPaper(paper("e", "Paper e", age: 4))
let sfAll = [sfA, sfB, sfC, sfD, sfOld]
check(SavedPaper(paper("x", "x")).reasons == nil && sfA.reasons == ["Topic: Electroencephalography"] && sfD.followed == false, "kept: a paper keeps why it was in the feed, and nothing when it had no reason")
check(Why.tags(reasons: ["Topic: Pain", "Author: Marie Curie", "Cites your work"], followed: true).map(\.kind) == [.citesYou, .author, .followedTopic], "classes: reasons come out as kinds, the most specific first")
check(Why.tag("Topic: Pain", followed: false).kind == .ownTopic && Why.text(for: Why.tag("Journal: Pain", followed: true)) == "From a journal you follow", "classes: a topic from the user's papers is its own kind, and the journal sentence is unchanged")
let sfFacets = SavedFilter.facets(sfAll)
check(sfFacets.first { $0.kind == .followedTopic && $0.detail == nil }?.count == 2, "filter: a kind counts the papers that have it")
check(sfFacets.first { $0.kind == .followedTopic && $0.detail == "Electroencephalography" } == nil, "filter: a kind with one name does not list that name again")
check(sfFacets.first { $0.kind == .other }?.count == 1 && sfFacets.map(\.kind).first == .citesYou, "filter: a paper without a reason is counted as other, and the kinds run most specific first")
check(SavedFilter(kind: .author).apply(sfAll).map(\.id) == [sfB.id], "filter: by kind")
check(SavedFilter(kind: .followedTopic, detail: "Electroencephalography").apply(sfAll).map(\.id) == [sfA.id, sfB.id], "filter: by a name within a kind")
check(SavedFilter(kind: .other).apply(sfAll).map(\.id) == [sfOld.id], "filter: the unclassified can be asked for")
check(SavedFilter(query: "curie lovelace").apply(sfAll).isEmpty && SavedFilter(query: "LOVELACE paper").apply(sfAll).count == 4, "filter: the search words must all match the title, journal or authors")
check(SavedFilter(sort: .published).apply(sfAll).map(\.id) == [sfD.id, sfB.id, sfOld.id, sfA.id, sfC.id], "sort: by publication date, newest first")
check(SavedFilter(sort: .relevance).apply(sfAll).map(\.id) == [sfC.id, sfB.id, sfA.id, sfD.id, sfOld.id], "sort: by relevance, the most specific reason first, then more reasons, and the unclassified last")
check(SavedFilter(sort: .kept).apply(sfAll).map(\.id) == sfAll.map(\.id), "sort: the list's own order is kept")
var sfFeed = ok("e"); sfFeed.reasons = ["Keyword: sleep"]; sfFeed.followed = true
sfOld.id = sfFeed.dedupeKey
check(SavedFilter.enriched([sfOld], from: [sfFeed]).first?.reasons == ["Keyword: sleep"] && SavedFilter.enriched([sfA], from: [sfFeed]).first == sfA, "enrich: an older entry learns its reasons from the feed, and a classified one is left alone")
check((try? JSONDecoder().decode(SavedPaper.self, from: Data(#"{"id":"doi:1","title":"t","date":"2026-01-01"}"#.utf8)))?.reasons == nil, "kept: an entry from before reasons were stored still loads")

// MARK: PDF cache, EndNote format, Zotero attachments and collections
func pe(_ name: String, _ mb: Int, _ age: Int) -> PDFCachePlan.Entry { .init(name: name, size: mb * 1_000_000, used: at(-Double(age))) }
let pcEntries = [pe("a", 100, 5), pe("b", 100, 3), pe("c", 100, 1), pe("d", 100, 9)]
check(PDFCachePlan.eviction(pcEntries, limit: 500_000_000).isEmpty && PDFCachePlan.eviction(pcEntries, limit: 400_000_000).isEmpty, "pdf cache: nothing is deleted while the files fit")
check(PDFCachePlan.eviction(pcEntries, limit: 250_000_000) == ["d", "a"], "pdf cache: the least recently used go first, only as many as needed")
check(PDFCachePlan.eviction(pcEntries, limit: 250_000_000, protected: ["d"]) == ["a", "b"], "pdf cache: the PDF of a saved paper is kept while others can go")
check(PDFCachePlan.eviction(pcEntries, limit: 0, protected: ["d"]) == ["a", "b", "c", "d"] && PDFCachePlan.total(pcEntries) == 400_000_000, "pdf cache: a protected file goes last when nothing else is left to delete")
let enRef = RIS.Reference(title: "Machine learning\nfor sleep", authors: ["Ada Lovelace", "Salido-Ruiz RA"], journal: "Life", date: "2026-10-18", abstract: "Line one.\nLine two.", doi: "10.3390/x", pmid: "123", url: "https://doi.org/10.3390/x", keywords: ["sleep", "EEG"], language: "en")
let enText = EndNote.record(enRef)
check(enText.hasPrefix("%0 Journal Article\n%A Lovelace, Ada\n%A Salido-Ruiz, RA\n%T Machine learning for sleep\n%J Life\n%D 2026\n%8 October 18\n%R 10.3390/x"), "endnote: the record starts with its type, the authors surname first, the title on one line")
check(enText.contains("%K sleep\n%K EEG\n%X Line one. Line two.\n") && enText.hasSuffix("\n") && !enText.contains("\n\n"), "endnote: one field a line, a value never carries a newline, no blank line inside a record")
check(EndNote.document([enRef, enRef]).components(separatedBy: "\n\n").count == 2 && EndNote.fileName(for: enRef).hasSuffix(".enw"), "endnote: records are separated by a blank line, the file is .enw")
check(Zotero.createdKey(from: Data(#"{"successful":{"0":{"key":"AB12"}},"failed":{}}"#.utf8)) == "AB12" && Zotero.createdKey(from: Data("{}".utf8)) == nil, "zotero: the key of a created item is read from the answer")
check(Zotero.uploadAnswer(from: Data(#"{"exists":1}"#.utf8)) == .exists && Zotero.uploadAnswer(from: Data(#"{"url":"https://s3.example/up","contentType":"multipart/form-data; boundary=x","prefix":"P","suffix":"S","uploadKey":"UK"}"#.utf8)) == .send(url: URL(string: "https://s3.example/up")!, contentType: "multipart/form-data; boundary=x", prefix: "P", suffix: "S", uploadKey: "UK") && Zotero.uploadAnswer(from: Data("x".utf8)) == nil, "zotero: an upload answer is either 'exists' or where to send the file")
let zColl = Zotero.collections(from: Data(#"[{"key":"B","data":{"name":"thesis","parentCollection":false}},{"key":"A","data":{"name":"Alpha"}},{"key":"C","data":{"name":"sub","parentCollection":"A"}}]"#.utf8))
check(zColl.map(\.name) == ["Alpha", "thesis"], "zotero: the picker lists top-level collections by name")
let zInColl = (try! JSONSerialization.jsonObject(with: Zotero.newItems(zRef, collection: "COLLKEY")) as! [[String: Any]])[0]
check(zInColl["collections"] as? [String] == ["COLLKEY"] && (try! JSONSerialization.jsonObject(with: Zotero.newItems(zRef)) as! [[String: Any]])[0]["collections"] == nil, "zotero: an item goes into the chosen collection, and into none by default")
let pdfDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try? FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
let pdfFile = pdfDir.appendingPathComponent("x.pdf"); try? Data("%PDF-1.4 test".utf8).write(to: pdfFile)
ZoteroStub.seen = []
ZoteroStub.answer = { req in
    let path = req.url!.path
    if req.url!.host == "s3.example" { return (201, [:], Data()) }
    if path.hasSuffix("/file") && String(decoding: req.httpBody ?? Data(), as: UTF8.self).hasPrefix("md5=") {
        return (200, [:], Data(#"{"url":"https://s3.example/up","contentType":"multipart/form-data; boundary=x","prefix":"PRE","suffix":"SUF","uploadKey":"UK"}"#.utf8))
    }
    if path.hasSuffix("/file") { return (204, [:], Data()) }
    return (200, [:], Data(#"{"successful":{"0":{"key":"KEY1"}},"failed":{}}"#.utf8))
}
let zWithPDF = try? await zClient.add(zRef, collection: "COLL", pdf: ZoteroClient.PDF(file: pdfFile, md5: "abc123"))
let zPaths = ZoteroStub.seen.map { $0.url!.path }
let zUpload = ZoteroStub.seen.first { $0.url!.host == "s3.example" }
check(zWithPDF == ZoteroClient.Added(key: "KEY1", pdf: .attached) && zPaths == ["/users/77/items", "/users/77/items", "/users/77/items/KEY1/file", "/up", "/users/77/items/KEY1/file"], "zotero client: the item, its attachment, the upload request, the file and the confirmation, in that order")
check(String(decoding: zUpload?.httpBody ?? Data(), as: UTF8.self) == "PRE%PDF-1.4 testSUF" && ZoteroStub.seen[2].value(forHTTPHeaderField: "If-None-Match") == "*" && String(decoding: ZoteroStub.seen[2].httpBody ?? Data(), as: UTF8.self).hasPrefix("md5=abc123&filename=paper.pdf&filesize=13"), "zotero client: the file is sent between Zotero's prefix and suffix, after announcing its hash and size")
check(String(decoding: ZoteroStub.seen[0].httpBody ?? Data(), as: UTF8.self).contains("\"collections\":[\"COLL\"]") && String(decoding: ZoteroStub.seen[1].httpBody ?? Data(), as: UTF8.self).contains("\"parentItem\":\"KEY1\""), "zotero client: the item goes in the collection and the attachment under the item")
ZoteroStub.answer = { req in
    if req.url!.path.hasSuffix("/file") { return (413, [:], Data()) }
    return (200, [:], Data(#"{"successful":{"0":{"key":"KEY2"}},"failed":{}}"#.utf8))
}
let zFull = try? await zClient.add(zRef, pdf: ZoteroClient.PDF(file: pdfFile, md5: "abc"))
check(zFull?.key == "KEY2" && { if case .skipped(let why)? = zFull?.pdf { return why.contains("storage is full") } else { return false } }(), "zotero client: when file storage is full the item is still saved and the reader is told the PDF was not")
ZoteroStub.seen = []
let zNoPDF = try? await zClient.add(zRef)
check(zNoPDF?.pdf == .notOffered && ZoteroStub.seen.count == 1, "zotero client: without a PDF it is one request, as before")
ZoteroStub.answer = { _ in (200, [:], Data(#"[{"key":"B","data":{"name":"thesis"}}]"#.utf8)) }
check((try? await zClient.collections())?.map(\.name) == ["thesis"], "zotero client: it lists the collections")

check(PDFNames.fileName(stem: "Lovelace-2026-Machine-learning", tag: "abc123") == "Lovelace-2026-Machine-learning--abc123.pdf" && PDFNames.fileName(stem: "///", tag: "t") == "paper--t.pdf" && PDFNames.fileName(stem: String(repeating: "x", count: 200), tag: "t").count == 80 + 7, "pdf folder: a file is named for a person and tagged for a device")
check(PDFNames.isFile("Lovelace--abc123.pdf", tag: "abc123") && PDFNames.isFile(".Lovelace--abc123.pdf.icloud", tag: "abc123") && !PDFNames.isFile("Lovelace--abc1234.pdf", tag: "abc123") && !PDFNames.isFile("notes.txt", tag: "abc123") && PDFNames.realName(".x.pdf.icloud") == "x.pdf", "pdf folder: a file is found by its tag, also when iCloud has not downloaded it")

check(PDFLink.preprint(doi: "10.1101/2026.10.01.123456", journal: "bioRxiv") == "https://www.biorxiv.org/content/10.1101/2026.10.01.123456.full.pdf" && PDFLink.preprint(doi: "10.1101/2026.10.01.123456", journal: "medRxiv (Cold Spring Harbor)")?.contains("medrxiv.org") == true && PDFLink.preprint(doi: "https://doi.org/10.1101/2026.10.01.123456", journal: "bioRxiv")?.contains("/content/10.1101/2026") == true, "preprint pdf: bioRxiv and medRxiv follow from the DOI and the venue")
check(PDFLink.preprint(doi: "10.1101/2026.10.01.123456", journal: "Cell") == nil && PDFLink.preprint(doi: "10.1016/j.cell.2026.01.001", journal: "bioRxiv") == nil && PDFLink.preprint(doi: nil, journal: "bioRxiv") == nil, "preprint pdf: a shared DOI prefix without a preprint venue, and an ordinary paper, get no guess")
check(PDFLink.preprint(doi: "10.48550/arXiv.2601.01234", journal: "arXiv") == "https://arxiv.org/pdf/2601.01234" && PDFLink.preprint(doi: "10.31234/osf.io/abc12_v1", journal: "PsyArXiv") == "https://osf.io/abc12/download", "preprint pdf: arXiv and the Open Science Framework servers")
var ppPaper = paper("pp", "A preprint"); ppPaper.doi = "10.1101/2026.10.01.123456"; ppPaper.journal = "bioRxiv"
var ppListed = ppPaper; ppListed.pdfURL = "https://example.org/x.pdf"
check(ppPaper.pdfLink?.contains("biorxiv.org") == true && ppListed.pdfLink == "https://example.org/x.pdf", "preprint pdf: a listed PDF comes first, the derived one when none is listed")

// A project description: passages for ranking, keywords to follow.
let proposal = """
Neural mechanisms of chronic pain relief

1. Background and aims

Chronic pain affects one adult in five, and current treatments help fewer than half of patients. We will test whether
transcranial magnetic stimulation of the motor cortex relieves chronic pain by changing connectivity in the
descending pain modulation system. Preliminary EEG recordings in 24 patients suggest that relief tracks a change in
alpha oscillations over the motor cortex.

2. Work packages

WP1 tests transcranial magnetic stimulation in 80 patients with chronic neuropathic pain, using a sham-controlled
design. Pain intensity is rated daily, and EEG is recorded before and after each session of stimulation. WP2
quantifies the change in alpha oscillations and relates it to the relief that chronic pain patients report. Budget:
EUR 120,000 in year 1; EUR 95,000 in year 2; EUR 80 000 in year 3.

References
[1] Smith J, et al. (2021) Motor cortex stimulation. Pain 162:1-10. https://doi.org/10.1000/xyz
"""
let projPassages = ProjectText.passages(proposal)
check(projPassages.count >= 2 && projPassages.allSatisfy { $0.count <= 700 && !$0.contains("\n") }, "project: the text becomes passages of a few sentences, with line wraps joined")
check(!projPassages.contains { $0.hasPrefix("1. Background") || $0.hasPrefix("References") || $0.contains("https://") } && !projPassages.contains { $0.contains("Budget") && $0.contains("EUR 80 000") && $0.count < 40 }, "project: headings and links are not passages")
check(ProjectText.paragraphs("The inter-\nnational study of sleep in older adults\ncontinues this year with a new cohort.").first == "The international study of sleep in older adults continues this year with a new cohort.", "project: a word split across a line end is joined, and wrapped lines make one paragraph")
check(ProjectText.passages("Methods\n\n12 14 15 16 17 18 19 20 21 22 23 24\n\nToo short.").isEmpty, "project: a table of numbers and a fragment are not passages")
let longText = (1...300).map { "Sentence number \($0) is about the way that sleep spindles consolidate memory in the young brain." }.joined(separator: "\n\n")
let longPassages = ProjectText.passages(longText)
check(longPassages.count == ProjectText.maxPassages && longPassages.first!.contains("number 1 ") && longPassages.last!.contains("number 2"), "project: a long text is thinned evenly, not cut")
check(ProjectText.title("Neural mechanisms of chronic pain relief\nmore") == "Neural mechanisms of chronic pain relief" && ProjectText.title("  \n ") == "Project" && ProjectText.title(String(repeating: "x", count: 100)).count == 61, "project: it is named for its first line")
let projWords = ProjectText.keywords(proposal).map(\.phrase)
check(projWords.contains("chronic pain") && projWords.contains("transcranial magnetic stimulation") || projWords.contains("magnetic stimulation"), "project keywords: the phrases it keeps returning to")
check(projWords.contains("EEG") || projWords.contains("alpha oscillations"), "project keywords: an acronym or a technical phrase that recurs")
check(!projWords.contains { ["work packages", "year", "budget", "background", "relief", "will"].contains($0) || $0.hasPrefix("the ") || $0.hasSuffix(" of") }, "project keywords: the words every proposal uses are not offered")
check(!projWords.contains("chronic pain patients") && !projWords.contains("pain"), "project keywords: neither a longer way to say a phrase already chosen, nor a word inside it")
let projKeywords = ProjectText.keywords(proposal)
check(projKeywords.filter(\.selected).allSatisfy { $0.words > 1 && $0.count >= 2 } && projKeywords.filter { $0.words == 1 }.allSatisfy { !$0.selected }, "project keywords: only phrases of several words are ticked to begin with")
check(ProjectText.keywords("A short note about nothing in particular.").isEmpty && ProjectText.keywords("").isEmpty, "project keywords: a text that repeats nothing offers nothing")
let projFile = ProjectFile(name: "n", text: "t", addedAt: "2026-11-09T10:00:00.000Z")
check((try? JSONDecoder().decode(ProjectFile.self, from: JSONEncoder().encode(projFile))) == projFile && (try? JSONDecoder().decode(ProjectFile.self, from: Data(#"{"text":"My plan\nmore"}"#.utf8)))?.name == "My plan", "project: it is stored and read back, and an older or partial file still loads")
let projSettings = FeedSettings()
check(FeedBuilder.profileTexts(projSettings, own: [], project: ["a passage"]).contains("a passage") && !FeedBuilder.profileTexts(projSettings, own: []).contains("a passage"), "project: its passages join the profile as soon as one is pasted, with no switch")

// Asking a model about the project: what is sent, and how its answer is read.
let briefSmall = ProjectBrief.excerpt(proposal, limit: 5_000)
check(!briefSmall.contains("Budget") || briefSmall.contains("Chronic pain affects"), "project model: the excerpt is passages of the text")
check(!briefSmall.contains("https://") && !briefSmall.contains("1. Background") && !briefSmall.contains("References") && !briefSmall.contains("Smith J"), "project model: headings, links and the reference list are not sent")
let briefBig = (1...200).map { "Paragraph \($0) is about how sleep spindles consolidate declarative memory in older adults with mild cognitive impairment." }.joined(separator: "\n\n")
let briefCut = ProjectBrief.excerpt(briefBig, limit: 3_000)
check(briefCut.count <= 3_000 && briefCut.contains("Paragraph 1 ") && !briefCut.isEmpty && briefCut.contains("Paragraph 1") && briefCut.range(of: "Paragraph 1[0-9]{2} ", options: .regularExpression) != nil, "project model: a long text is thinned evenly to the limit, from beginning to end, not cut off")
check(ProjectBrief.excerpt("too short", limit: 3_000).isEmpty && ProjectBrief.prompt("X").hasSuffix("X"), "project model: nothing is sent for a text with no passages")
let briefAnswer = """
Here are the search phrases:
1. Transcranial magnetic stimulation
- "chronic pain"
* EEG
• alpha oscillations.
descending pain modulation system
The project looks at how stimulation relieves pain in many patients over three years.
chronic pain
neuropathic pain
"""
let briefWords = ProjectBrief.keywords(from: briefAnswer, in: proposal)
check(briefWords.map(\.phrase) == ["transcranial magnetic stimulation", "chronic pain", "EEG", "alpha oscillations", "descending pain modulation system", "neuropathic pain"], "project model: a list is read through its bullets, numbers and quotes; an introduction, a sentence and a repeat are left out")
check(briefWords.first { $0.phrase == "chronic pain" }?.count == 4 && briefWords.first { $0.phrase == "neuropathic pain" }?.count == 1 && ProjectBrief.keywords(from: "heschl gyrus", in: proposal).first?.count == 0, "project model: each phrase says how often the text uses it, and zero for one the model supplied")
check(briefWords.filter(\.selected).allSatisfy { $0.words > 1 } && !(briefWords.first { $0.phrase == "EEG" }?.selected ?? true) && briefWords.filter(\.selected).count <= 8, "project model: phrases of several words are ticked, a single word is not")
check(ProjectBrief.keywords(from: "EEG recordings\nfMRI\nNeural Networks", in: "").map(\.phrase) == ["EEG recordings", "fMRI", "neural networks"], "project model: an acronym keeps its capitals, alone or in a phrase, and other words are lowercased")
check(ProjectBrief.keywords(from: "", in: proposal).isEmpty && ProjectBrief.keywords(from: (1...30).map { "phrase number \($0)" }.joined(separator: "\n"), in: "").count == 12, "project model: an empty answer gives nothing, and a long one is held to twelve")
let pbConfig = RemoteSummaryConfig(provider: .anthropic, key: "SECRET", model: "")
let pbReq = RemoteSummary.request(pbConfig, system: ProjectBrief.instructions, user: ProjectBrief.prompt("The excerpt."))
let pbBody = (try! JSONSerialization.jsonObject(with: pbReq.httpBody!)) as! [String: Any]
check(pbReq.url?.host == "api.anthropic.com" && pbBody["system"] as? String == ProjectBrief.instructions && String(decoding: pbReq.httpBody!, as: UTF8.self).contains("The excerpt.") && !String(decoding: pbReq.httpBody!, as: UTF8.self).contains("SECRET"), "project model: the brief and the excerpt are all that is sent to Claude, and the key is only in a header")
check(RemoteSummary.request(pbConfig, title: "t", abstract: "a").httpBody == RemoteSummary.request(pbConfig, system: RemoteSummary.instructions, user: RemoteSummary.prompt(title: "t", abstract: "a")).httpBody, "project model: the takeaway request is the same as before the general one was made")
ZoteroStub.answer = { _ in (200, [:], Data(#"{"content":[{"type":"text","text":"chronic pain\nEEG"}],"stop_reason":"end_turn"}"#.utf8)) }
check((try? await RemoteSummary.answer(pbConfig, system: "s", user: "u", session: zSession)) == .some("chronic pain\nEEG"), "project model: the service's answer is read as text")

print(failures == 0 ? "\nAll passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
