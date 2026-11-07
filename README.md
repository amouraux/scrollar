# Scrollar

A feed for researchers: scroll through new papers from the journals, topics,
people and keywords you follow, ranked by how close they are to your own work.

Status: prototype. The core runs from the command line; there is no app yet.

```sh
Tests/run.sh                      # pure functions, no network, no key
./run.sh 0000-0000-0000-0000      # ORCID in, ranked feed out (needs a key)
```

## Key

OpenAlex needs a free key (<https://openalex.org/settings/api>). Copy
`Secrets.example` to `Secrets.local` and put the key in it. `Secrets.local` is
gitignored; do not compile a key into the app. In the app, each user will paste
their own into Settings and it will live in the Keychain.

## Layout

- `Core/Model.swift`, `Seed.swift`, `Ranking.swift`: Foundation only, tested.
- `Core/OpenAlex.swift`: the only file that touches the network.
- `CLI/main.swift`: prototype driver.

Every seed (a topic, journal, author, keyword, or "cites my work") becomes one
OpenAlex query. Results are merged by DOI, ranked, and each card keeps the
reasons it appeared.
