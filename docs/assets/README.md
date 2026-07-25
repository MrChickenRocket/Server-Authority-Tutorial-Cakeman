# Screenshots and clips

Captured from the running place. Named for the chapter and step that uses them, so a missing
image is obvious in the article.

## Embedding

Plain markdown handles animated GIFs, and GitHub plays them inline. No HTML needed:

```markdown
![The cube driving, truth overlay on](assets/01-step7-truth-overlay.gif)
```

Reach for HTML only when you need to **control the width**, which markdown can't do. GitHub
renders `<img>` inside markdown:

```markdown
<img src="assets/02-wobble.gif" width="640" alt="Mid-turn, arms flung out">
```

Two things GitHub will *not* do from a repo path, so don't plan around them:

- **`<video>` tags are stripped** when GitHub renders repo markdown. MP4 only plays if you
  upload it to an issue, PR or release, which gives you a CDN link rather than a repo file.
- **No lazy loading or click-to-play.** Every GIF on a page downloads and animates as soon
  as the page opens, so a chapter with ten heavy clips is a slow page for everyone.

## Keep them small

Git stores every version of a binary forever, so an oversized clip is a permanent cost, and
re-exporting it five times means five copies in history. Aim for **under 2 MB**, and treat
5 MB as a hard ceiling.

What actually gets you there, in order of effect:

1. **Crop and downscale.** 640px wide is plenty for an inline clip; most of the frame is
   usually baseplate.
2. **Cut the length.** Two to four seconds. A loop that makes its point in three seconds is
   a better teaching image than a ten-second one anyway.
3. **Drop the frame rate** to 15–20 fps. Physics wobble reads fine at 15.
4. **Reduce the palette.** GIF is limited to 256 colours; forcing 64 often halves the file
   with no visible loss on a flat-shaded Roblox scene.

**Animated WebP** is worth knowing about: GitHub renders it, it animates, and it is
routinely 3–10× smaller than the equivalent GIF. If a clip refuses to come under budget as
a GIF, export WebP instead — the markdown is identical.

If the clips ever get genuinely large in aggregate, move them to **git-lfs** before
committing rather than after; rewriting history to extract them later is far more painful
than setting it up first.

## Shot list

Chapter 1:

| File | Step | Shows |
|---|---|---|
| `01-step1-authoritymode.png` | 1 | Workspace Properties with AuthorityMode = Server |
| `01-step2-explorer.png` | 2 | The four scripts in Explorer at their paths |
| `01-step2-output.png` | 2 | `[CubeServer] ready` / `spawned Cube_…` |
| `01-step4-nocamera.png` | 4 | The characterless view before the camera exists |
| `01-part1-driving.gif` | Part 1 check | The cube driving on the baseplate |
| `01-step7-truth-overlay.gif` | 7 | Red raw physics behind the smoothed copy |

Chapter 2:

| File | Step | Shows |
|---|---|---|
| `02-step3-gizmo-wrong.png` | 3 | Joint gizmos with the cone on its side |
| `02-step3-gizmo-right.png` | 3 | The same joints with X down the chain |
| `02-step5-waist.png` | 5 | The tapered silhouette against a uniform stack |
| `02-cakeman.png` | — | The finished character, standing |
| `02-wobble.gif` | — | Mid-turn, arms flung out by the turn rate |
| `02-punch.gif` | Part 3 | A landed punch and the knockback |

The two gizmo shots are the highest-value images in the article: that bug is invisible in
code review and obvious in a picture.
