# CakeMan — the tutorial

Draft chapters. One file each, plain markdown, meant to be edited.

| # | File | Status | What it teaches |
|---|---|---|---|
| 0 | [00-orientation.md](00-orientation.md) | draft | What we're building, and why the ragdoll IS the character |
| 1 | [01-place-zero.md](01-place-zero.md) | draft | AuthorityMode, no Humanoids, and the two lines everyone forgets |
| 2 | [02-the-rig.md](02-the-rig.md) | draft | A cake of ball sockets — as a baked artefact, not boot code |
| 3 | [03-input-and-the-brain.md](03-input-and-the-brain.md) | draft | InputActions, the shared sim, the four rules, the velocity servo |
| 4 | [04-camera.md](04-camera.md) | draft | You own the camera now. SA took PlayerModule away. |
| 5 | [05-the-world.md](05-the-world.md) | draft | An arena of bases, bridges and death pits — and where instances may be created |
| 6 | [06-prediction.md](06-prediction.md) | draft | The chapter I got wrong twice. Prediction is not yours to micromanage. |
| 7 | [07-presentation.md](07-presentation.md) | draft | Smooth a copy, never the physics. And the CanQuery footgun. |
| 8 | [08-combat.md](08-combat.md) | draft | Damage is momentum — and the velocity in `Touched` is the wrong one |
| 9 | [09-the-grab.md](09-the-grab.md) | draft | The wrestler's guard, reaction forces, and tension you can't read |
| 10 | [10-knockout-and-respawn.md](10-knockout-and-respawn.md) | draft | Ragdoll by subtraction, and what a respawn silently keeps |
| 11 | [11-feel.md](11-feel.md) | draft | The knobs, in the order you should turn them |
| 12 | [12-going-further.md](12-going-further.md) | draft | Legs, and everything I tore out to get here |

## House style for these drafts

- Every claim is something we actually measured in the place. If a number is in
  the text, it came out of a trace, not out of the air.
- Failures stay in. The bugs are the tutorial — a chapter where everything works
  first time teaches nobody anything.
- Code in the chapters is the code in the repo. If they disagree, the repo wins
  and the chapter is wrong.

## Screenshots

`assets/` — captured from the running place. Named for the chapter that uses them.
