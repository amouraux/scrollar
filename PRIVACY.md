# Scrollar privacy policy

*Last updated: 9 November 2026.*

Scrollar builds a feed of research papers from open scholarly services. It has no servers of its own, no account, no analytics, no advertising and no tracking. **The developer receives no data from the app.**

## What stays on your device

Your settings (what you follow and mute, sliders), the papers on your reading list, marked For me or read, and the title and abstract of papers you hid (kept so that papers like them can be ranked lower, for a limited time), your reading history, cached feeds and summaries, downloaded PDFs and any project description you paste (a grant proposal, say) are stored on your device. A project description is not synced and is not in an exported settings file. It is read on the device, and sent to no service, unless you choose to ask Claude or ChatGPT to suggest keywords from it (below); only a keyword you choose to follow from it is searched, like any other. API keys you type (OpenAlex, Zotero, Claude or OpenAI) are stored in the device Keychain and are sent only to the service they belong to.

If you choose a sync file or a folder in iCloud Drive, Scrollar reads and writes it. It is your file in your iCloud; the developer cannot see it. A backup file you export is yours as well.

## Services the app contacts directly

The app contacts these services from your device, and they receive your IP address and what is needed to answer:

- **OpenAlex** (api.openalex.org) and **Europe PMC** (ebi.ac.uk) and **PubMed / NCBI** (eutils.ncbi.nlm.nih.gov): the topics, keywords, authors, journals, institutions, funders, DOIs and PMIDs your feed is built from, and the ORCID iD you enter so your own publications can be found. If you give an OpenAlex key, it is sent to OpenAlex.
- **Crossref** (api.crossref.org), **arXiv** (export.arxiv.org) and the **Open Science Framework** (api.osf.io), only if switched on in Tune, Sources (Crossref is on by default, but asked only when OpenAlex is off; arXiv and OSF are off until you turn them on): the keywords, journal names and author names you follow, as a search (OSF is asked for keywords only). Nothing else is sent.
- **Zotero** (api.zotero.org), only if you connect an account: your key, to read the titles, abstracts and tags of your newest items and to add papers (and their PDFs) you choose.
- **Claude (Anthropic) or ChatGPT (OpenAI)**, only if you add your own key under Summaries and AI: the title and abstract of papers that stay on screen, to write a short takeaway. Nothing else is sent, except in one case you start yourself: in Tune, Your project, asking Claude or ChatGPT to suggest keywords sends an excerpt of the project description you pasted (passages of its text, without headings, tables, links or reference lists), after a screen that says who receives it and shows exactly what will be sent, and each time you ask. The service handles it under your account and its own terms. Apple's on-device model, where your device has one, can do the same without sending anything off the device.
- **Publishers and repositories**, when you open a paper's PDF or link: the address you open is requested from that site, as in a browser.

Apple's on-device language model, when used, runs on the device.

## Choices

You can disconnect Zotero, remove keys, clear downloaded PDFs, stop using a sync file or folder, and delete the app to remove everything stored on the device. Delete the sync file or folder in iCloud Drive to remove what was kept there.

## Children

The app is not directed at children and collects nothing from anyone.

## Contact

andre.mouraux@gmail.com
