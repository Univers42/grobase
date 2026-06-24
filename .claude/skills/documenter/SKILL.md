---
name: documentation-wiki
description: >-
  Turn sprawling, redundant, jargon-heavy technical writing into a navigable wiki that a
  competent outsider can actually read. Use this whenever the user wants to write, restructure,
  or clean up documentation, a README, a project dossier, a wiki, an architecture doc, or any
  long-form technical explainer — and ESPECIALLY when they mention redundancy, "humanizing"
  text, undefined terms, walls of jargon, docs that are "hard to read", or turning a linear
  document into something browsable. Trigger this even if the user just pastes a long doc and
  says "make this better" or "clean this up", since that almost always means this work.
---

# Documentation → Wiki

A skill for converting linear, repetitive, jargon-dense documents into a **wiki**: a set of
short pages a reader can enter from anywhere, understand without the rest, and trust to state
each fact exactly once.

The default failure mode of technical writing is not too little information — it's the same
information restated five times in five registers, wrapped in terms nobody defined, opened by
sentences that say nothing. This skill exists to fix that without dumbing anything down.

---

## What a good wiki is (and why a dossier isn't one)

A **dossier** is read once, front to back, by someone who has to. A **wiki** is entered at a
random page by someone in a hurry. That single difference drives every rule below.

A good wiki has six properties:

- **Enterable from anywhere.** Each page stands on its own: a reader who lands there from a
  search result gets oriented in the first two sentences and finds links to whatever context
  they're missing. No page assumes you read the previous one.
- **One page, one question.** A page answers a single concern ("How does auth work?", "What is
  the query-router?"). When a page tries to answer three questions, split it.
- **Says each fact once.** Every fact has exactly one home — its _canonical page_. Everywhere
  else, you link to it. This is the property a dossier almost never has.
- **Layered.** The top of a page is plain language (what + why). The middle is the mechanism
  (how). The bottom is the detail (code, config, edge cases). A reader stops at the depth they
  need and leaves.
- **Defines its own vocabulary.** Every term that isn't general programming knowledge is defined
  once, on first use, and collected in one glossary. Nothing technical is dropped raw.
- **Obvious where new facts go.** The structure makes the home of any future fact predictable, so
  the wiki stays clean as it grows instead of re-accreting redundancy.

When you write or refactor, you are optimizing for these six. If a change improves one without
hurting the others, make it.

---

## The reader you are writing for

Write for a **competent outsider**: a working developer who is sharp but does _not_ know your
stack. This is the single most useful calibration in the skill, because it cuts both ways:

- Do **not** explain general knowledge. They know what a database, an HTTP request, a JWT, and a
  container are. Explaining those insults them and bloats the page.
- Do **explain everything specific to you.** They have never heard of _your_ `query-router`, _your_
  `grobase` plans, _your_ "shadow → parity → cutover" discipline, or why you chose Trino. These
  must be defined the first time they appear.

The test for any sentence: _would a smart developer who has never seen this repo understand it,
and learn something they couldn't have guessed?_ If no on the first clause, define more. If no on
the second, cut it.

---

## Workflow

Do not start rewriting prose. Documentation refactoring fails when you edit sentence-by-sentence,
because redundancy and bad structure are properties of the _whole_, not of any one paragraph.
Work in this order.

### 1. Inventory the facts and the duplication

Read the whole source. Build two lists:

- **Distinct facts / claims** — the actual information content, ignoring how often it's repeated.
  ("Public traffic goes WAF → Kong." "RLS enforces `owner_id = auth.uid()` at the database." "The
  Rust data plane uses 11.5 MiB; the Node equivalent used 127 MiB.")
- **A redundancy map** — for each fact that appears more than once, list every location. This map
  is the refactor's main target. (In a typical dossier, the same security litany — WAF, Kong, RLS,
  `owner_id`, Vault, secrets-out-of-Git — reappears in nearly every chapter.)

Report the duplication map to the user before restructuring. It's the clearest possible evidence
of where the 90% reduction will come from.

### 2. Design the information architecture before writing a word

Propose the page tree — the list of pages and what single question each one owns — and get the
user's agreement. A typical project wiki:

```
wiki/
├── README.md            # the map: what this is, who it's for, where to go (one screen)
├── overview.md          # the 5-minute version: problem, shape, key decisions
├── concepts/            # one page per recurring idea (auth, data-plane, isolation model…)
├── reference/           # exhaustive lookup: API routes, env vars, schema, CLI
├── decisions/           # why-we-chose-X, including paths abandoned (ADR-style)
├── operations/          # run it, deploy it, back it up, observe it
└── glossary.md          # every defined term, once
```

Each fact from step 1 gets assigned to exactly one page — its canonical home.

### 3. Extract the glossary first

Pull every term that fails the "competent outsider" test into `glossary.md` with a one-or-two
sentence plain definition. Do this _before_ rewriting pages, so that while rewriting you can link
to the glossary instead of re-explaining inline. The glossary is the tool that lets you obey the
define-once rule across many pages.

### 4. Migrate — move facts, don't copy them

Walk the redundancy map. For each duplicated fact: keep it on its canonical page, and at every
other location **replace the restatement with a link** ("Public traffic routing is described in
[Security model](concepts/security.md)."). This step alone produces most of the size reduction.

### 5. Rewrite each page through the rule sets

Now, and only now, write prose — one page at a time, through rule sets A–D below. A page is done
when it passes all four gates in §Verification.

### 6. Verify against the gates

Run the gates in §Verification over every page. Report the before/after word count for the
sections you compressed, and the count of undefined terms eliminated.

---

## Rule set A — structure & page format

ALWAYS give every page this anatomy:

```markdown
# [Page title — the question this page answers]

> One sentence: what this page covers and who needs it.

[Plain-language layer: 1–3 short paragraphs. What is this, why does it exist,
what problem does it solve. No code, minimal jargon.]

## [Mechanism heading]

[How it works. Diagrams here if structure/flow is involved.]

## [Detail heading]

[Code, config, edge cases — the layer most readers skip.]

---

**See also:** [linked pages for context this page deliberately omits]
```

- **Lead with the answer.** The first paragraph states the conclusion. Never make a reader
  scroll through setup to learn what the page is about.
- **Layered disclosure is mandatory.** Plain → mechanism → detail, top to bottom. A reader must be
  able to stop after the plain layer and have learned something true and complete-at-that-level.
- **Headings are descriptive and searchable.** "Why we dropped Express" not "Discussion". The
  heading should tell a skimming reader whether this section answers their question.
- **Pick the right medium per content type:**
  - _Prose_ — reasoning, decisions, "why". Default.
  - _Table_ — comparing items across the same dimensions (engines × capabilities, tier × cost).
  - _Diagram (Mermaid)_ — structure, flow, sequence. One diagram per distinct relationship; never
    paste two near-identical diagrams.
  - _Code block_ — a real, minimal excerpt, with a path comment on line 1 and a one-line caption
    saying _why this code matters_. Never dump a whole file; show the 5–15 lines that make the point.
- **Cross-link instead of recapping.** A link is the wiki's substitute for repetition.

---

## Rule set B — eliminate redundancy (the 90% target)

Redundancy is the primary disease. These rules are mechanical; apply them literally.

- **Single source of truth.** Each fact lives on exactly one page. If you're about to state
  something the reader could already have read elsewhere in the wiki, link instead.
- **The deletion test.** For every sentence, ask: _does this give the reader information they don't
  already have on this page or a linked one?_ If no, delete it. Apply ruthlessly to summaries.
- **One summary per unit, maximum.** A dossier accretes "Le fil rouge", "En résumé", "En une
  phrase", "Bilan du chapitre", "Ce que ça veut dire concrètement" — multiple restatements of the
  same paragraph. Keep at most one summary per page, and only if it adds a frame the body lacked.
- **Collapse repeated scaffolding.** When many tables share the same column framing ("Skill | What
  it means here | Proof in repo"), state the framing once and don't re-narrate it above every table.
- **Hoist repeated caveats.** A status caveat repeated verbatim in ten places (e.g. "shadow by
  default in code, but active in the deployed compose") is one fact. State it once on its canonical
  page; elsewhere link or reference a short status table.
- **Don't re-derive defined concepts.** Once a concept is defined (RLS, `owner_id`, the outbox
  pattern), later pages name it and link — they do not re-explain it inline.
- **Merge near-duplicate pages.** Two pages covering 80% the same ground become one page; the
  unique 20% becomes a section or a linked sub-page.

Measure it: track word count of the redundant sections before and after. The reduction is the
deliverable, and you report the number.

---

## Rule set C — accessibility without oversimplifying

The goal is to make hard things understandable, not to make them sound easy or remove their depth.

- **Define on first use, exactly once.** The first time a non-general term appears, gloss it in one
  clause — `RLS (Row-Level Security: the database filters each row by the logged-in user)` — and
  add it to the glossary. Subsequent uses are bare. Over-glossing (repeating the parenthetical
  every time) is itself redundancy; fix it.
- **No undefined acronym, ever.** Expand on first use. If you can't define a term in one clause,
  it needs its own glossary entry or its own page.
- **Layered disclosure carries the load.** Accessibility comes from letting the reader stop early,
  not from deleting the hard parts. The hard parts move _down_ the page, they don't disappear.
- **Analogy on a leash.** One analogy per concept is allowed and often great ("TLS is a sealed,
  tamper-evident envelope; the certificate is the server's ID card"). Rule: the analogy must be
  immediately followed by the literal mechanism, and must never be the _only_ explanation. An
  analogy that replaces the truth is a lie the reader will act on.
- **Concrete before abstract.** Pair every abstract claim with a concrete instance within two
  sentences. "The hot path is light" → "a hot query runs in ~2 ms in 11.5 MiB of RAM." Numbers,
  paths, and named things beat adjectives.
- **Don't explain the universe.** Cut explanations of general programming concepts. Spend the
  reader's attention on what's specific to this system.

---

## Rule set D — humanize (operational rules, not vibes)

"Humanize" is not an instruction — it's the result of obeying concrete constraints. Apply these;
do not just aim for a "human tone".

**Banned phrases — delete on sight.** These are the fingerprints of generated/corporate prose and
they carry zero information:

> "it's worth noting that", "it's important to understand", "it should be noted", "essentially",
> "fundamentally", "in essence", "at its core", "in today's world", "in the modern era", "as we all
> know", "needless to say", "when it comes to", "in order to" (→ "to"), "a wide range of",
> "leverage" (→ "use"), "utilize" (→ "use"), "robust", "seamless", "cutting-edge", "powerful"
> (as filler), "delve into", "navigate the complexities of".

**Kill emphasis adverbs.** "very", "really", "highly", "extremely", "significantly", "incredibly"
almost always weaken the sentence. Remove them or replace the weak word they prop up with a strong
one. "very fast" → "instant" or a number.

**Vary sentence length.** Generated text drifts toward uniform medium-length sentences. Every
paragraph must contain at least one short sentence (under ~8 words). Short sentences land. Use them.

**Name the agent. Use active voice.** "We chose Trino because…" not "Trino was chosen because…".
Who did what, and why. Passive voice hides the decision-maker and reads like a manual nobody wrote.

**One idea per sentence.** No three-concept comma-splices. If a sentence has two "and"s and a
comma joining independent clauses, break it.

**No throat-clearing openers.** Don't open a page or section with a generic windup ("AI is now an
essential part of modern projects…"). Open with the specific claim. Compare:

- Windup: "Security is probably the part of the project where the most can go wrong."
- Direct: "Security here is defense in depth: if one layer is bypassed, the next still holds."

**Real transitions, not connective filler.** Don't start consecutive paragraphs with "Moreover",
"Furthermore", "Additionally". Connect ideas by their logic, or just start the next point.

**Admit the cost.** Human technical writing names trade-offs and the paths it abandoned. "We tried
a Node monolith. It lasted two weeks." That sentence is more credible and more useful than any
amount of polish. Keep the seams; they're where the reader learns.

**Don't open consecutive paragraphs the same way.** Vary the first few words. Repetitive paragraph
openings are a strong tell of machine generation.

A page that obeys D reads like a sharp engineer explaining their system to a peer over coffee —
direct, concrete, occasionally blunt about what didn't work. That _is_ "humanized".

---

## Verification

A page ships only when it passes all four gates. Run them explicitly per page.

- **Redundancy gate.** No fact on this page is stated elsewhere in the wiki as anything but a link.
  No more than one summary. No repeated scaffolding narration. (Spot-check by searching the wiki for
  a distinctive phrase from the page — it should appear once.)
- **Jargon gate.** Every non-general term is defined exactly once (here or in the glossary) and
  appears bare thereafter. Zero undefined acronyms. Zero raw, never-explained technology names.
- **Accessibility gate.** The first paragraph is plain language and states the answer. A competent
  outsider could read the plain layer and explain the page's point to someone else. The hard detail
  is present, just lower.
- **Humanization gate.** Zero banned phrases. Emphasis adverbs removed. Every paragraph has a short
  sentence. Active voice with named agents. No throat-clearing openers. Trade-offs stated where they
  exist.

Then report: before/after word count for compressed sections, and the number of terms moved to the
glossary.

---

## Output language

Write the wiki in the **same language as the source material.** If the source dossier is in French,
produce French wiki pages (the rules above are language-agnostic — banned-phrase lists and
glossing apply equally to "il convient de noter que", "en somme", etc.). Keep file and directory
names in the language with which the documente was written (en->english, fr->french) by convention unless the user says otherwise.

---

## Worked examples and tailored patterns

For concrete before/after rewrites — drawn from the exact redundancy and jargon patterns this skill
is meant to catch — and a full mini-refactor of one dossier section into wiki pages, read
[references/rewrite-patterns.md](references/rewrite-patterns.md). Read it before your first rewrite
on a new project; it shows the rules applied, not just stated.
