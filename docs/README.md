# The article

| # | File | What it covers |
|---|---|---|
| 1 | [01-the-method.md](01-the-method.md) | The three-part method, built end to end on a sliding cube: server character, client prediction, presentation layer. Four files, ~200 lines, runnable. |
| 2 | [02-building-cakeman.md](02-building-cakeman.md) | The same four files, with the cube replaced by a floppy cake on ball sockets with noodle arms. |

Start at the [repository README](../README.md) if you're new here.

`assets/` — screenshots, captured from the running place and named for the chapter and step
that uses them. See [assets/README.md](assets/README.md) for the shot list.

---

## House style

Working notes for anyone editing these two files.

**Voice.** Plain instructor, second person, present tense. No byline, no war stories as
structure. Author experience appears as a stated measurement or a named hazard, never as an
anecdote carrying the paragraph. Competence throughout — the audience includes people
evaluating the work, so every passage has to read as expert. Friendly is fine; flailing is
not.

**Structure.** Numbered steps, continuous across the chapter. Each step says what to do,
then why, then a **Check:** the reader can actually run. Insight comes after the step, not
instead of it.

**Traps stay in** — they're the useful part — but each one lives at the step where it bites,
framed as a hazard a good engineer learns to spot and diagnose.

**Avoid the "X isn't A, it's B" construction.** State what a thing is. If naming the wrong
option carries real instructional load (a mistake readers actually make), say so plainly as
an instruction.

**No options, no futuring.** Nothing about what you *could* build next, and no alternative
approaches presented side by side. Pick the one that works and teach that.

**Just how to do it.** No recorded measurements, no side investigations, no war stories, no
"here's what went wrong when we tried X". Numbers in the text are *settings* the reader
types, never observations we made.

**A gotcha only survives if it's an instruction.** "Set `CanQuery = false` or your raycasts
hit the visual copy" stays, because skipping it builds something broken. The story of how we
found that out does not.

**No disclaimers.** This has been run under real latency and it works. Don't hedge it.

**Code in the chapters is the code in the repo.** If they disagree, the repo wins and the
chapter is wrong. Chapter 1's blocks are verified line-for-line against `samples/cube/`.

## Retired drafts

An earlier 15-chapter version covered the full brawler — combat, the grab, the knockout,
arena design, tuning. It was retired when the scope became a two-chapter article. The
originals are in commit `62fba56` under their pre-renumber filenames
(`docs/01-place-zero.md`, `docs/02-the-rig.md`, and so on).
