# Server Authority reference

Everything known about building under `Workspace.AuthorityMode = Server`, written to be
usable on any Server Authority project — not only the character in this repo.

Written for agents as much as for people. Rules are stated as imperatives with the trigger
that makes them apply; failure modes are tabulated symptom → cause → fix; every code block
is runnable as written. Almost every Server Authority failure mode is silent, so the tables
are the point.

| File | Read it when |
|---|---|
| **[rules.md](rules.md)** | Always. The invariants, the banned-inside-the-sim table, the silent-failure table, the setup checklist. Load this first. |
| [server-authority.md](server-authority.md) | You need the platform: what the engine does, what enabling it changes, Simulation Access, prediction control, what mispredictions cost, current limitations, test modes. |
| [patterns.md](patterns.md) | You are writing code. Project shape, the shared sim module, input, effects, clocks, constraints, presentation, prediction tuning, camera, characterless setups, debug workflow. |
| [physics-characters.md](physics-characters.md) | The character is a real ragdoll driven by forces. Rollback-safe architecture, mass and joints, locomotion, steering, omni-surface traversal, chains, feel tuning. |

## Scope

The two chapters in [`docs/`](../) teach the method by building one thing end to end. This
folder is the reference behind them: no build order, no narrative, everything stated as a
rule with the conditions under which it applies.

Different genre, different rules from the chapters' house style. **Measurements stay** —
they are what makes a claim checkable and a number tunable. Numbers here are observations
unless labelled as a setting, which is the opposite of the convention in the chapters.

## Status

Current as of the **July 2026 full release**. Version-sensitive observations name the Studio
version they were taken on.

One thing is flagged in place rather than resolved: the exact rejection behavior for a
non-simulation-access write inside `BindToSimulation` has not been measured. See
[server-authority.md](server-authority.md#simulation-access).
