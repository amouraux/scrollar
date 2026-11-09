#!/bin/sh
# Compiles only the Foundation-only core files with the tests: no network, no
# key, no simulator.
set -e
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 Core/Model.swift Core/Kind.swift Core/Seed.swift Core/PubMed.swift Core/Settings.swift Core/FeedBuilder.swift Core/History.swift Core/Cover.swift Core/Incremental.swift Core/Summary.swift Core/Byline.swift Core/Why.swift Core/SavedFilter.swift Core/PDFCachePlan.swift Core/EndNote.swift Core/FeedbackMemory.swift Core/ReferenceManager.swift Core/Crossref.swift Core/Osf.swift Core/Arxiv.swift Core/Project.swift Core/ProjectBrief.swift Core/Reader.swift Core/RIS.swift Core/RemoteSummary.swift Core/LibraryImport.swift Core/Zotero.swift Core/ZoteroClient.swift Core/Sources.swift Core/Sync.swift Core/Profile.swift Core/Layout.swift Core/Backup.swift Core/Preview.swift Core/Ranking.swift Tests/main.swift -o .build/tests
.build/tests
