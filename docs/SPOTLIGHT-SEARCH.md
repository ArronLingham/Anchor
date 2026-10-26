# Spotlight research and Anchor Launchpad search

Research date: October 21, 2026.

## How a search engine chooses results

Search has separate jobs: collect eligible documents; normalize queries and fields;
retrieve plausible candidates; rank those candidates; show an actionable result;
and learn from successful interactions. A ranking algorithm cannot recover an app
that discovery never indexed. Conversely, retrieving every loose letter match makes
ranking noisy even when discovery is correct.

The [Stanford information retrieval textbook](https://nlp.stanford.edu/IR-book/html/htmledition/irbook.html)
separates tokenization, normalization, tolerant retrieval, field weighting, ranked
retrieval, feedback, and evaluation. These are useful design tools for launchers.
An app catalog has short titles and hundreds of entries, rather than long documents
and millions of pages: term-frequency statistics or link popularity are less useful
than recognizable names, word starts, abbreviations, and fast execution. This is
an engineering inference for Anchor, not a claim about Apple's implementation.

Specific references informed the implementation:
[normalization](https://nlp.stanford.edu/IR-book/html/htmledition/normalization-equivalence-classing-of-terms-1.html)
explains consistent treatment of query/document forms and the danger of over-broad
expansion; [edit distance](https://nlp.stanford.edu/IR-book/html/htmledition/edit-distance-1.html)
provides a basis for bounded spelling recovery;
[field scoring](https://nlp.stanford.edu/IR-book/html/htmledition/weighted-zone-scoring-1.html)
motivates distinguishing title evidence from context; and
[ranked evaluation](https://nlp.stanford.edu/IR-book/html/htmledition/evaluation-of-ranked-retrieval-results-1.html)
explains why finding an item somewhere in the results is weaker evidence than
ranking it near the top. For a launcher, the first result deserves particular
attention because Return opens it. Anchor uses explicit tiers rather than the
textbook's additive field formula, to prevent context from overpowering names.

## What Apple actually discloses

- [Spotlight indexing](https://support.apple.com/en-gb/102321): device content is
  collected in a private local index, updated as content changes. Index coverage
  and exclusions affect what can be retrieved.
- [Search on Mac](https://support.apple.com/en-gb/guide/mac-help/mchlp1008/mac):
  results arrive while typing, with top matches first; users can narrow searches.
- [Core Spotlight user queries](https://developer.apple.com/documentation/corespotlight/csuserquery):
  human queries support lexical and semantic retrieval, ranked results, suggestions,
  cancellation, and interaction reporting.
- [WWDC24: Support semantic search](https://developer.apple.com/videos/play/wwdc2024/10131/):
  engagement and freshness affect adaptive ranking. Apple's framework supports
  usage updates and query-specific selection signals. Semantic models require
  device resources and run in the host app process.
- [Search interface guidance](https://developer.apple.com/documentation/corespotlight/building-a-search-interface-for-your-app):
  index app-owned content, request necessary fields, cancel obsolete queries, and
  debounce expensive asynchronous queries. Semantic support starts with macOS 15.
- [Metadata ranking hints](https://developer.apple.com/documentation/corespotlight/cssearchableitemattributeset/rankinghint):
  hints express relative importance among similar indexed items. The same metadata
  system includes alternate names, titles, keywords, content types, and dates.
- [TN2416](https://developer.apple.com/library/archive/technotes/tn2416/_index.html):
  older iOS guidance advocates related synonyms and abbreviations, consistent item
  identifiers, fresh content, and fast opening. This is historical cross-platform
  guidance, not proof of current macOS scoring weights.

Apple does **not** disclose Spotlight's complete system ranking formula or its
weights. Core Spotlight's public app-content APIs are not a supported interface
for obtaining the complete system Spotlight app catalog and its exact ordering.
Nothing here claims to reproduce Spotlight's private model. Typo handling and
Anchor's explicit relevance tiers below are our own choices.

## Existing Anchor behavior and identified defects

Anchor already discovers apps on directory changes, caches the catalog, performs
dynamic-programming fuzzy matching, searches categories/folders, and maintains
frequency weighted by a ten-day recency half-life. Those are valuable foundations.

Previously the search added `history * 4` to text scores without a cap. A heavily
used app could eventually beat a much stronger textual match. Every regular app
also ranked above every search-only utility, even for an exact utility name.
Name/category/folder checks used `else if`, so a weak name subsequence could hide
a better metadata match. Folder iteration could select different matching fields
based on dictionary order. Launch failures were counted as successful usage.

## Implemented policy

`LauncherSearch.swift` is the pure ranking component used by `AppIndex.search`,
launcher commands, and quicklink title search.

| Tier | Evidence |
| --- | --- |
| 7 | Exact displayed name |
| 6 | Displayed name prefix |
| 5 | Word prefix, full initials, all query word prefixes; strongest alternate-name matches |
| 4 | Contiguous substring |
| 3 | Useful fuzzy subsequence |
| 2 | Single-edit full-word typo recovery |
| 1 | Category or folder context |

Within a tier, lexical quality plus `min(24, 4 * log2(1 + frecency))` determines
order. The existing ten-day decay remains intact. Usage cannot cross tiers. Within
a tier, regular apps precede search-only utilities; remaining ties use localized
name and then path for stable output in AppIndex; the merged UI resolves remaining
ties by stable result ID. An exact
utility match can win while home browsing still hides search-only utilities.

Every eligible name, alias, category, and folder is considered; only the best
field contributes, so duplicate aliases do not inflate scores. Context fields
require exact/prefix word evidence, preventing broad fuzzy category matches.
Aliases include bundle filename and declared/localized bundle names, plus a small
identity-keyed compatibility list: System Preferences, Task Manager, VS Code,
Disk Manager, Web Browser, Email, and Code Editor. These are explicit synonyms,
not general semantic search.

Queries fold case, accents and fullwidth forms, and collapse whitespace. Highlight
positions map back to original graphemes, including case-fold expansions. Multiple
words can appear in any order, each must match a distinct word. There is no
silent dropping of unmatched terms. Single-word fuzzy abbreviations remain useful.
Typo recovery accepts one edit or adjacent transposition on a full word with at
least four query characters; short queries get no spelling expansion. Pasted
queries over 128 characters are rejected before fuzzy DP allocations.

Only successful NSWorkspace application opens record usage. There is no new
persistent search history, telemetry, network dependency, timer, model download,
or filesystem access per search. Existing empty-query sorting remains.

Apps, commands, and Shortcuts now share the same relevance scale in list results.
Previously all commands were rendered before all apps regardless of relevance. A
single ordered entry list now drives display, arrow navigation, scrolling, clicks,
and Return. Explicit quicklink keywords and direct URLs keep their priority above
ordinary matches. Within the same relevance tier, apps precede commands: `ss`
therefore surfaces System Settings above a similarly matching Show Screenshots
Shortcut. An exact command still outranks a partial app name. Lock-command intent
gating remains in place.

## Deliberate boundaries

Core Spotlight's semantic engine is useful for long prose and media. Introducing
it for this small app-name catalog would add asynchronous indexing/recovery and
model resource costs. Anchor therefore uses the disclosed principles locally.
Its in-memory results arrive synchronously; an artificial 300 ms delay would hurt
this path. If file/content search is added, native asynchronous queries with
cancellation and debounce should be considered separately.

This implementation does not learn a different favorite for each query, infer
work routines, search document contents, or train a semantic model. General app
usage remains the personalization signal. Multiword typos and mixed title-plus-
category queries are not supported. Scope is Launchpad application and command search. Calculator and app switcher
retain their existing behavior.

## Validation

- `bash tests/run_launcher_search_tests.sh`: production matcher/ranker regressions
  for ranking, aliases, multiword queries, errors, Unicode, bounds, and frecency.
- `bash tests/run_launcher_tests.sh`: existing matching/calculator regressions.
- `bash tests/run_launcher_experience_tests.sh`: existing launcher experience checks.
- Debug-only `ANCHOR_SEARCH_REVIEW=1` with `ANCHOR_RENDER_UI=<directory>` runs
  actual AppIndex searches against this Mac's installed catalog and writes
  `search-results.txt`; Release does not expose the snapshot environment hook.

Measured results and installed build verification are recorded in
`SPOTLIGHT-SEARCH-VALIDATION.md`.
