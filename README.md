# Spiderbrain

A handwritten, infinitely expandable mind map for iPad and Apple Pencil, driven
simultaneously from a MacBook.

**Status: M1** — the ink engine spike. One stroke, one screen, no canvas, no graph,
no sync. Its only job is to answer one question: *does custom Metal ink feel as good
as PencilKit?* If it doesn't, that's a cheap thing to learn now.

Architecture plan: <https://claude.ai/code/artifact/8d358062-0301-457c-ba3d-1539a7e3c21a>

## Layout

```
SpiderbrainKit/          Swift package — all the real logic
  Sources/SpiderbrainKit/
    Model/               InkPoint, InkStyle, Stroke
    Geometry/            Vec2, PressureCurve, StrokeSmoother, Tessellator
    Input/               StrokeInputCollector  (iOS only)
    Render/              InkShaders, InkRenderer, MetalInkView  (iOS only)
  Tests/                 Pure-geometry tests — no GPU, no simulator
App/                     Demo app source, to paste into an Xcode project
canvas-chat/             Structural reference only. Not a dependency.
```

`Model/` and `Geometry/` import nothing but Foundation. That's deliberate: the whole
geometry core is testable with `swift test` on any Mac, and it's the layer that
eventually gets shared with the macOS target.

## Running it

You need a Mac with Xcode and **a physical iPad** — the simulator has no Metal
device and no Pencil, so the app will trap on launch there.

### 1. Run the tests first

```bash
cd SpiderbrainKit
swift test
```

No device needed. If this is green, the smoothing, pressure curve, and tessellation
are behaving.

### 2. Create the app target

Xcode has no way to open a loose folder of Swift files as an app, so:

1. **File → New → Project → iOS → App**
   - Product name: `SpiderbrainInk`
   - Interface: **SwiftUI**, Language: **Swift**
   - Save it next to `SpiderbrainKit/` (in this same `spiderbrain/` folder).
2. **File → Add Package Dependencies… → Add Local…** and choose the
   `SpiderbrainKit` folder.
3. Add `SpiderbrainKit` to the app target's **Frameworks, Libraries, and Embedded
   Content**.
4. Replace the generated `ContentView.swift` and `SpiderbrainInkApp.swift` with the
   two files in `App/`.
5. Select your iPad as the run destination and build.

### 3. What to do with it

Draw a paragraph of real handwriting. Then flip the **engine** switch at the top and
draw the same paragraph in PencilKit. You are looking at one thing: the gap between
the nib and the ink.

Then turn **Prediction** off and write again. That difference is what
`predictedTouches` is buying you, and feeling it is the fastest way to understand
why the input layer is built the way it is.

## What is actually implemented

| Piece | Where | Notes |
| --- | --- | --- |
| Coalesced touches | `StrokeInputCollector.update` | Recovers the 240 Hz sample stream that `touchesMoved` drops |
| Predicted touches | `StrokeInputCollector.update` | Provisional tip, replaced every event, never accumulated |
| Estimated-property corrections | `StrokeInputCollector.applyEstimatedUpdate` | Patches force and altitude when the Pencil sends corrections |
| 120 Hz display link | `MetalInkView.configure` | ProMotion parks at 60 unless asked |
| Centripetal Catmull-Rom | `StrokeSmoother` | Interpolating, so ink lands where the pen went; no cusps on sharp corners |
| Even arc-length resampling | `StrokeSmoother.walk` | Width varies smoothly instead of tracking irregular sample spacing |
| Pressure and tilt to width | `PressureCurve` | Smoothstep with a floor, plus tilt broadening |
| Round caps and ribbon body | `Tessellator` | Non-indexed triangle list |
| Two-pass correct blending | `InkRenderer.draw` | Opaque offscreen with MSAA, composited once at real alpha |
| Latency HUD | `ContentView` | fps, CPU frame time, sample and correction counts |

## Known M1 limits

These are scope, not bugs. Each is handled in a later milestone.

- **Committed strokes are re-uploaded as geometry**, not rasterised into tiles. Fine
  for a page of scribble, wrong for a document. M2.
- **One ink alpha at a time.** The single composite pass carries one alpha, so pen
  and highlighter can't coexist yet. When they need to, group strokes by style and
  composite per group.
- **No canvas.** No pan, no zoom, no camera. Coordinates are view points. M2.
- **Undo re-tessellates everything.** Correct, and irrelevant at this scale.
- **Shaders compile at runtime** from a string in `InkShaders.swift`, to keep the
  build system out of the spike. Move to a `.metal` file before shipping.

## Next

M2 is the infinite canvas: two-finger pan and zoom while the Pencil keeps drawing,
tiling, the committed/live split, camera-relative coordinates, and the throwaway
region prototype that decides how ink becomes nodes.

## Two layout traps, already handled

Worth knowing about, because both fail silently rather than loudly:

- **Vertex struct alignment.** Metal aligns `float3` to 16 bytes, so a naive
  `{ float2; float3; }` is 32 bytes while the Swift `InkVertex` is 20. Every vertex
  after the first would read garbage. The shader uses `packed_float2` / `packed_float3`
  so both sides agree at stride 20. Any change to `InkVertex` must be mirrored in
  `InkShaders.swift`.
- **Premultiplied resolve.** MSAA resolve already premultiplies: a half-covered texel
  averages to `(colour * 0.5, 0.5)`. The composite shader must not multiply by alpha
  a second time, or every antialiased edge darkens.
