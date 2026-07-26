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

- **`<video>` tags are stripped** when GitHub renders repo markdown. An MP4 committed to
  the repo cannot play inline, however you reference it.
- **No lazy loading or click-to-play.** Every GIF on a page downloads and animates as soon
  as the page opens, so a chapter with ten heavy clips is a slow page for everyone.

## Video that does play: the attachment URL

MP4 works if GitHub is hosting it rather than the repo. Uploading a file to any issue or PR
comment puts it on GitHub's CDN and hands you a URL that renders as a **player** in
markdown — including in the README.

1. Open a new issue on the repo. Don't submit it.
2. Drag the MP4 into the comment box and wait for the upload to finish.
3. It becomes a `https://github.com/user-attachments/assets/...` URL. Copy that.
4. Close the issue tab without posting.
5. Paste the URL into the markdown **as a bare URL on its own line**. No `![]()`, no
   `<video>` — GitHub expands it into a player.

This keeps large clips out of git entirely, which is why the hero clips on the landing page
use it. The trade is that the file lives on GitHub's CDN rather than in your history, so it
is not in a clone and not under your control if the repo moves.

Use it for **hero clips and anything long**. Use a committed GIF or WebP for **small
in-line clips inside a chapter**, where a reader benefits from it being right there in the
page and in the repo.

Source `.mp4` files are gitignored so a 17 MB recording can't be committed by accident. If
you deliberately want one in the repo, `git add -f` it.

## Keep them small

Git stores every version of a binary forever, so an oversized clip is a permanent cost, and
re-exporting it five times means five copies in history. Aim for **under 3 MB** on a hero
clip and **under 1 MB** for anything inline in a chapter. Treat 5 MB as a hard ceiling.

The levers, in order of effect:

1. **Cut the length.** By far the biggest win, and a shorter loop is usually a better
   teaching image anyway. Seven seconds is plenty for a hero clip; two to four for an
   inline one.
2. **Crop and downscale.** 640px wide is plenty; most of the frame is usually baseplate.
3. **Quality**, before frame rate. libwebp `-q:v` around 40–45 holds up well on flat-shaded
   Roblox scenes.
4. **Frame rate last.** 15 fps looks visibly choppy on wobbling physics — 30 is worth
   paying for, and paying for it out of duration is the better trade.

The command used for the clips here:

```
ffmpeg -ss 6 -t 7 -i clip.mp4 \
  -vf "fps=30,scale=640:-2:flags=lanczos" \
  -c:v libwebp -lossless 0 -q:v 40 -compression_level 6 -loop 0 -an \
  out.webp
```

**Verifying the result is awkward.** `ffprobe` reports "image data not found" on animated
WebP and ffmpeg cannot decode its own output — it encodes animation through libwebp but its
native decoder ignores `ANMF` chunks. So check the container instead: it should be
`RIFF`/`WEBP`, the `VP8X` flags byte should have the animation bit set, and the count of
`ANMF` chunks should equal duration × fps.

```bash
od -An -c out.webp | tr -d ' \n' | grep -o 'ANMF' | wc -l   # = frame count
```

Then open it in a browser or on GitHub, because that is the only real test.

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
