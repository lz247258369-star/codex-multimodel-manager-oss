# Motion Design System v1

Codex Multi-Model Manager V4 uses one shared motion language instead of ad-hoc animation values in individual controls.

## Principles

1. Motion communicates state; it is not decoration.
2. Entering elements use **EaseOut**: react quickly, then settle gently.
3. Leaving elements use **EaseIn**: start quietly, then get out of the way.
4. Spatial movement uses **EaseInOut**: slow at both ends, faster in the middle.
5. Continuous progress/loading uses **Linear** only while work is actually running.
6. Important product moments may use the shared **Signature** cubic-bezier curve.
7. Windows reduced-motion / client-animation preference is respected when available.
8. No page, card, particle, glow, or other decorative animation runs forever.

## Duration tokens

| Token | Duration | Intended use |
| --- | ---: | --- |
| `Fast` | 100 ms | press feedback, tiny state response |
| `Exit` | 130 ms | element exit / close |
| `Enter` | 160 ms | card, menu, panel entrance |
| `Move` | 220 ms | page movement, spatial transition |
| `Smooth` | 220 ms | expand/collapse and coordinated movement |
| `Emphasized` | 280 ms | important model/state transition |
| `LinearLoop` | 900 ms | active loading/progress rotation only |

## Curve tokens

The WPF implementation uses `KeySpline`, equivalent to CSS cubic-bezier control points.

| Curve | cubic-bezier | Intended use |
| --- | --- | --- |
| `Linear` | `(0, 0, 1, 1)` | loading / continuous motion |
| `EaseIn` | `(0.4, 0, 1, 1)` | exit / close |
| `EaseOut` | `(0, 0, 0.2, 1)` | enter / open |
| `EaseInOut` | `(0.4, 0, 0.2, 1)` | movement / page transition |
| `Signature` | `(0.16, 1, 0.3, 1)` | Codex emphasized state change |

## V4 mapping

- Model-card and button micro-interactions use the shared spline engine.
- Top-level page navigation enters with `EaseOut + Enter` and settles spatially with `EaseInOut + Move`.
- Price/performance sorting re-settles the model grid with `EaseOut + Enter` plus `Signature + Emphasized`.
- Dropdown selectors use a short `EaseOut` entrance response.
- A reusable linear loop exists for real loading indicators, but is never started automatically as decoration.

## Product rule

Commercial polish means consistent response, timing and hierarchy—not maximum animation. If a motion does not explain state, confirm an action, or preserve spatial continuity, leave it static.
