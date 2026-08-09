# What limits 3D scan quality on an iPhone

Notes from building [ObjectScanner](https://github.com/burakSahinkaya/ObjectScanner),
an open-source iOS scanner with four capture modes. Everything here was measured on
device or on a Mac against real captures. Where I guessed and was wrong, that is
written down too, because the wrong guesses cost more time than the right answers
saved.

Written for people who have a scan that came out badly and want to know which of the
possible causes it actually is.

## The short version

- Poor quality is usually a **capture** problem or a **platform ceiling**, almost never
  a settings problem. `PhotogrammetrySession.Configuration` has no quality dial.
- iOS reconstruction is capped at `.reduced`, roughly **25,000 triangles**. A Mac at
  `.raw` produced **331,116** from the same frames. Treat the on-device model as a
  preview.
- `.raw` is **not** higher-poly than `.full`. Identical geometry, different material
  maps. If you are picking a level to ship, `.full` is usually the one.
- Chasing resolution is mostly wasted effort. Coverage is the lever.
- `Request.poses` turns "it looks bad" into three numbers that each point at a
  different fix. Wire it up before you start guessing.

---

## 1. Texture is an input, not an output

The single most useful idea here, and it is counter-intuitive.

Photogrammetry knows where a surface is because it can find the same visual detail in
several photographs and triangulate it. Visual pattern is the *only* source of
frame-to-frame correspondence, and therefore the only source of geometry. A surface
with no pattern produces no correspondences and therefore no geometry, no matter how
good the light is or how many photographs you take.

This predicts what will work before you shoot anything:

| Surface | Photogrammetry | Depth sensor (LiDAR / TrueDepth) |
|---|---|---|
| Textured, matte | Best geometry available | Good, coarser |
| Flat single colour | Softens, detail lost | Fine |
| Matte black | Fine | Holes, IR is absorbed |
| Glossy or metallic | Poor | Poor |

The two columns fail in different places, which is why a scanner wants more than one
technique rather than one technique with a quality slider.

It also explains the room case, which trips up nearly everyone who tries it. A room is
not a large object. Its walls are the worst possible photogrammetry subject: large,
flat, evenly painted, no pattern. Room-scale photogrammetry gives a result that is
reasonable on the room's *contents* and torn along its *envelope* — precisely inverted
from what you wanted. That is why RoomPlan exists as a separate framework: LiDAR plus
a trained classifier, emitting walls, doors, windows, openings and furniture as
understood entities. It succeeds on exactly the surfaces photogrammetry starves on.
Its trade-off is that a chair becomes a chair-shaped box.

Glossy objects deserve a warning of their own. A reflection moves when you move, so
the "detail" the solver latches onto is not attached to the surface. It is worse than
no texture, because the matches are confidently wrong.

## 2. The iOS detail ceiling

`PhotogrammetrySession.Request.Detail` declares **only `.reduced` on iOS**. The
`.medium`, `.full` and `.raw` cases are macOS-only. This is not a documentation
subtlety, it is in the interface:

```
$ grep -A6 "public enum Detail" RealityFoundation.swiftinterface
public enum Detail : Swift::Int, Swift::Hashable {
  case reduced
  ...
```

`reduced` is a fixed budget per model — roughly 25,000 triangles and a single texture.
It does not scale with how much you captured. That budget is generous for a game
controller and hopeless for a room, and it is the reason a room scan can look
unrecognisable even when every frame aligned perfectly.

Same 75 frames, reprocessed:

| | Triangles | File | Result |
|---|---|---|---|
| iOS, `reduced` | ~25,000 | — | mushy, hard to identify |
| Mac, `raw` | **331,116** | 36.7 MB | furniture recognisable, textured |

**About 13×.** For a single small object the gap is much smaller — I measured 2.3× —
because 25,000 triangles is closer to sufficient there. The ceiling hurts in
proportion to how much space you are trying to describe.

The practical consequence is an architecture decision rather than a tuning one: treat
the on-device model as a preview, keep the source images, and offer a route to a Mac.
In this project that is a one-tap zip export plus a small command line tool.

### `.raw` is not the highest quality

Everyone assumes `raw` > `full` > `medium`. For geometry that is false. `raw` and
`full` produce **identical meshes**. They differ only in material maps: `full` bakes
its maps, `raw` leaves them raw, including a 22 MB displacement map that most viewers
will not use.

So `raw` gets you a much larger file and no extra geometry. Unless you are taking the
maps into a DCC tool yourself, `full` is the level you want.

## 3. Resolution is mostly a dead end

I spent real time trying to raise capture resolution, on the assumption that sharper
frames meant better geometry. Two measurements ended that.

`ARSession.captureHighResolutionFrame` can only deliver what the **currently running
video format** supports, and during a RoomPlan session RoomPlan chooses that format,
not you. On a room walk the high-resolution call yielded 2016 px against the live
stream's 1920. A few per cent, for a noticeably more complex code path.

And in the frames that already existed, alignment was not failing for want of pixels.
It was failing because of where the camera had and had not been. Which leads to the
thing that actually worked.

## 4. Capture geometry, measured

`PhotogrammetrySession.Request.poses` (iOS 17+) returns the solver's own camera
transforms. It rides along on alignment work the session is already doing, so it is
nearly free, and it converts a vague complaint into three numbers:

- **Alignment ratio** — how many of your frames the solver actually managed to place.
  Low means correspondence is failing: featureless or glossy surfaces, motion blur, or
  changing light between frames.
- **Azimuth coverage** — how much of a full turn the placed cameras span. A gap here
  is a hole in the model, and it is the one people are most surprised by, because
  walking around something feels complete.
- **Elevation spread** — the difference between the highest and lowest camera. Shoot
  everything from standing height and every camera sits on one ring with no vertical
  parallax, so the solver is weakly constrained in exactly the direction you gave it
  no information.

Each of those points at a *different* fix, which is the whole value. A soft mesh with
97% alignment and a wide elevation spread is not a capture problem, and re-walking will
not help it — that is the detail ceiling in section 2. A soft mesh with 60% alignment
is a capture problem and no amount of reprocessing will help.

### Where I got this wrong

I reported these angles for room captures too. A room walk measured 73 of 75 frames
aligned, 345° of azimuth, 75° of elevation. All healthy. The scan was poor.

The numbers were meaningless. Azimuth and elevation here are computed as directions
from the cameras to the scene centroid, which assumes the cameras are *outside* the
subject looking in. Walking through a room puts them inside the volume looking
outward, and some pass near the centroid where direction is numerically unstable.

So the app now reports angular measures only for orbit captures, and for interior
captures reports the alignment ratio alone. A healthy-looking number that means
nothing is worse than no number, because it sends you to look somewhere else.

## 5. What to do instead

The lever that actually improved results was telling the person capturing what they had
missed. People do not know. They think "I walked around the room", not "I have a 40°
wedge behind me with no data in it".

What helped, in order of how much:

1. **A coverage indicator.** Sixteen azimuth sectors in two rings, one for walls and
   one for the floor, filling in as they are covered, with a needle for where the
   camera points now and a haptic tick per newly covered direction. The floor needs its
   own ring because nobody points a phone downward unless asked.
2. **A second pass at a different height.** Cheap, and directly addresses the
   elevation-spread failure.
3. **Locking focus, exposure and white balance** for stationary-camera captures. Left
   automatic, focus breathing shifts the intrinsics between frames.
4. **Rejecting blurred frames at capture time**, scored on gradient energy, rather than
   discovering the problem after a five-minute solve.
5. **An object mask** where the camera is stationary and the object rotates. One
   rectangle covers every frame, and it is the reliable way to keep a table out of your
   model.

Note what is not on that list: any configuration value.
`PhotogrammetrySession.Configuration` exposes only `isObjectMaskingEnabled`,
`sampleOrdering`, `featureSensitivity`, `checkpointDirectory` and `ignoreBoundingBox`.
There is no quality setting to find.

One caution on masking: `isObjectMaskingEnabled` is actively harmful for a room. It
hunts for a single subject per frame and cuts away the rest, and in a room the room
*is* the subject. The Mac tool here takes a `--room` flag for exactly that reason.

---

## Reproducing the measurements

All three tools are single Swift files in [`Tools/`](../Tools), compiled with
`swiftc`. No dependencies.

```bash
# Full-detail reconstruction from a folder of images.
# Levels: preview | reduced | medium | full | raw
swiftc -O -parse-as-library Tools/Reconstruct.swift -o /tmp/reconstruct
/tmp/reconstruct ~/Downloads/frames ~/Desktop/model.usdz full

# Triangle and vertex counts, plus real bounding box.
# Every count in this document came from here.
swiftc -O -parse-as-library Tools/MeshStats.swift -o /tmp/meshstats
/tmp/meshstats model-a.usdz model-b.usdz

# Render four viewpoints to PNG, offscreen.
swiftc -O -parse-as-library Tools/RenderViews.swift -o /tmp/renderviews
/tmp/renderviews model.usdz output 1100
```

That last one exists because judging a scan means *looking* at it, and triangle counts
alone will mislead you. My `raw --room` room model had 13× the triangles and was still
a torn shell, which the number alone does not tell you. `qlmanage` stalls on a 36 MB
USDZ and `SCNView.snapshot()` wants a window, so `SCNRenderer` on a Metal device is
the way. Light it with ambient only — a directional light carves shadows that are easy
to mistake for real surface detail.

## Two API traps, since they cost the most time

Both of these fail *silently*, which is why they are worth naming.

`ObjectCaptureSession.startDetecting()` and `RoomCaptureSession.run(configuration:)`
both do nothing unless their view is already on screen **and laid out**. The first just
never starts detecting. The second renders into nothing and shows a black camera with
Apple's coaching animation drawn on top, so it does not even look like a failure.
`RoomCaptureView` is `public` rather than `open`, so you cannot subclass it to hook
`layoutSubviews` — wrap it in your own host view and gate on window plus non-zero
bounds. SwiftUI's `onAppear` is not a substitute, since it promises neither a window
nor a size.

And do not take `RoomCaptureSession.delegate` while using `RoomCaptureView`. That
delegate is what draws the live wireframe, so claiming it silently removes the feature
users rely on. Poll `captureSession.arSession.currentFrame` instead if you need to know
whether frames are arriving.

---

Corrections and better measurements are welcome — open an issue. The full architecture
and a longer list of SDK findings are in the
[README](https://github.com/burakSahinkaya/ObjectScanner#readme).
