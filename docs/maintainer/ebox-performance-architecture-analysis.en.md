# Ebox Performance Architecture Diagnosis and Redesign Direction

> Status: Architecture diagnosis and implementation checkpoint. This document records the performance gap between the current refactored `ebox` and the historical `emacs-box`, the evidence boundary, and the high-level redesign direction. Five narrow slices are implemented; the retained mounted-update architecture is not yet considered generally repaired.
>
> Date: 2026-08-07
>
> Revision: 2026-08-08. Following an independent architecture review, this document separates style cascade, projection, candidate preparation, pure render, and retained-TP coupling, lowers confidence where direct stage timing is still missing, and records isolated pure-materialization, candidate-handoff, partial-line scoped-projection, strict retained-viewport-reflow, and fixed-footprint copy-on-write checkpoints.

## Question

Why does the current refactored Ebox fail to match the performance of the pre-refactor `emacs-box` during dynamic content updates, viewport resize, and pure `ebox-render`? The data-flow and ownership causes must be established before optimizing individual functions.

## Conclusion

The regression is not primarily one function becoming slower. In the baseline retained data flow, computation scope is bound to the wrong whole-tree path: current Ebox connects “materialize the final propertized string” and “maintain a retained, incrementally updateable TP surface with stable identity,” while triggering whole-tree style cascade, projection, and candidate preparation on paths whose scope has not been narrowed.

Consequently, before the scoped slices, an update that ultimately needed one owner and one text operation still paid for whole-tree style computation, node projection, candidate preparation, and ownership/range construction first. The pre-slice path also repeated identity reconciliation. The partial-row checkpoint now removes the unnecessary projection/layout breadth for one stable owner shape, but unresolved paths can still expand; current stage data directly identifies style cascade and baseline projection as the largest measured costs, while it does not independently prove that TP identity, retain, or final publication is the single largest cost.

The key distinction is that current’s “local patch” describes publication granularity, not computation granularity. In legacy, a local update is usually local both in computation and publication. In current, only the final publication step is local. The retained TP boundary should therefore be treated as the architectural scope coupling that creates this problem, not as an independently proven intrinsic bottleneck. A strict retained `viewport-reflow` slice now closes one measured case: it reuses the retained node-object subtree while rerunning viewport layout, and rejects cascade, inheritance, scroll, visible-overflow, and topology cases back to the ordinary safe path.

## Scope and terminology

- “current” means the standalone refactored `ebox` repository.
- “legacy” means the sibling historical `emacs-box` source tree.
- “pure materialization” means producing a propertized render string from a source tree without a live buffer, stable retained identity, or rollback requirement.
- “retained publication” means publishing a candidate to a mounted TP surface with stable identity, ownership, scope proof, revision, and rollback semantics.
- Absolute timings come from one local measurement environment. The architecture conclusion relies on stage proportions, call counts, and identical outputs rather than on one absolute threshold.

## Stage-level evidence

### Dynamic content update

The same approximately 1712-node `dynamic-update-reference.ebox` fixture was used; the current parser constructs a tree of the same scale. The fixture has no stylesheet rule but does contain inline inherited style.

| Item | Current | Legacy | Direct observation |
| --- | ---: | ---: | --- |
| Total time | 12.127969s | 0.073844s | Output length is 1177 and SHA-256 is identical |
| Projection-start stage | 10.882838s | Not present | Current calls `ensure-node-tree` 1712 times; the interval boundary still needs a probe contract |
| Style computation | 1262 calls, about 8.99s | No equivalent stage | `ecss-compute-style` runs 1262 times, about 8.95s |
| Final text operations | 1 | Local patch | Current report is still `span-patch` with one dirty owner |
| TP structure statistics | 1716 reconciled objects; 378 property operations | Direct buffer/region path | TP publication is not the dominant source of time |

After current completes whole-tree projection and style computation, it needs only one local owner patch. Legacy formats only the target content and performs the local patch. This rules out text length and the text SHA-256 recorded by the current probe as the primary explanation, but the hash has not yet been shown to include complete text properties and therefore is not by itself an `equal-including-properties` proof.

### Viewport resize

For a `900 → 720` resize on the same fixture:

- Current takes `12.447619s`; projection-start takes `11.305584s`; `ensure-node-tree` still runs 1712 times and 1262 styles are computed.
- Current has only one TP text operation and 361 property operations; the Ebox report is `owner-rerender` with one dirty owner and scope one.
- Legacy takes `0.404387s` and renders approximately 51 local nodes; output length and SHA-256 match current.

Therefore, the name `owner-rerender` describes the final publication scope, not the scope of the preceding layout, style, candidate, and projection work. The strict retained viewport checkpoint now measures `node-projection=2`, `TP-object-preparation=5`, and `reconciled-objects=4` on the evaluator fixture; this is a proven safe subset, not evidence that every resize path has that closure.

### Pure `ebox-render`

On the same full fixture:

- Current takes `12.420715s`; `ebox-surface--project` takes `12.293075s`; projection-start takes `11.556190s`; `ecss-compute-style` runs 1262 times for about `9.34s`.
- Current `tp-surface-materialize-string` accounts for nearly the entire total because it enters the retained-surface construction path.
- Legacy takes `0.710261s`, directly executing layout/render without an equivalent TP surface projection.
- Both implementations produce length 1183 with identical SHA-256.

This shows that current `ebox-render` presents as a string-returning API but enters the retained-surface construction path internally. It establishes boundary coupling, but aggregate stages alone do not establish the independent cost of retained identity, bindings, or the ownership graph.

### Stylesheet A/B

On a 300-box tree without inline inheritance:

| Condition | Total time | Ebox style calls | ECSS calls | Output |
| --- | ---: | ---: | ---: | --- |
| No stylesheet | 0.481574s | 0 | 0 | Same length and SHA-256 as the other run |
| Add one `box` rule | 2.973969s | 301 | 301 | Same length and SHA-256 as the other run |

A stylesheet rule that does not change the final visual output is enough to switch the static tree onto a per-node cascade path. This makes “stylesheet active” an important trigger for style-computation expansion, rather than charging only for nodes whose effective style actually changed.

The dynamic fixture is triggered by inline inherited style, while the A/B fixture is triggered by a stylesheet rule; these are not the same trigger path. The document currently shows that both paths enter style computation, but does not establish that one snapshot/invalidation repair will produce the same benefit for both.

The three current totals are `12.127969s`, `12.447619s`, and `12.420715s`, varying by less than 3%; the corresponding legacy totals are `0.073844s`, `0.404387s`, and `0.710261s`. This supports a current fixed whole-tree cost that is weakly related to operation type and strongly related to tree size, but does not identify whether that cost comes from style, projection, candidate preparation, or retained construction.

## Implemented checkpoint: isolated static materialization

The first reversible architecture slice is now implemented for the narrow case where the source has no active stylesheet and does not require inline inherited-style computation. `ebox-render` creates an isolated candidate and render-side tables, then runs the raw layout/materialization path without constructing a retained TP object tree. Stylesheet-required pure renders and all mounted paths still use the retained surface path.

The declared evaluator confirms both the optimization and the boundary:

| Scenario | Elapsed | Relevant stage evidence | Correctness evidence |
| --- | ---: | --- | --- |
| Pure static | `0.047611s` | No node-projection, TP-object-preparation, or publication stage | Isolated output equals the TP-backed reference with `equal-including-properties` |
| Stylesheet pure | `0.171233s` | Cascade exercised; 21 `ecss-compute-style` calls | TP-backed output equality retained |
| Mounted content update | `0.061124s` | 3 node-projection calls, 5 TP-object-preparation calls | Mounted identity retained; `full-root=nil`, scope count `2`; TP reconciles 4 objects |
| Viewport resize | `0.044602s` | 28 node-projection calls, 58 TP-object-preparation calls | Root identity retained; `full-root=nil`, scope count `1`; TP reconciles 30 objects |

The earlier same-evaluator comparison was `0.037040s` before the slice and `0.025286s` after it (about 32% lower). The fresh values above are environment samples, not a replacement for the relative checkpoint. The slice proves that the pure static boundary removes retained projection work without changing output; it does not prove that mounted scoped updates are local in computation. The candidate-handoff boundary is now separately addressed below, while projection and layout still need a scope reduction.

## Implemented checkpoint: isolated candidate handoff

Region and scroll updates now pass their already-isolated runtime candidate through the incremental planner and surface producer. The internal handoff skips a second structural copy, declarative-root validation, and runtime-identity reconciliation; viewport updates deliberately do not use this flag because they start from the published root and still require the ordinary candidate policy.

The fresh evaluator and focused regression evidence are:

| Scenario | Candidate evidence | Remaining computation scope | Correctness evidence |
| --- | --- | --- | --- |
| Mounted content update | One candidate structural copy; no duplicate validation or reconciliation | `ensure-node-tree` 0 calls, node-projection 3 calls, layout/fragment/ownership 4 calls, TP-object-preparation 5 calls | Surface tests 32/32; commit tests 4/4; exact propertized output; mounted identity retained; `full-root=nil`, scope count `2`; TP reconciles 4 objects |
| Scroll update | Isolated candidate handoff is accepted without changing the TP contract | No independent scroll stage breakdown yet | Surface regression passes; TP revision/publication behavior remains valid |
| Viewport resize | Ordinary published-root candidate path remains unchanged | `ensure-node-tree` 26 calls, layout/fragment/ownership 7 calls, TP-object-preparation 58 calls | Exact output; root identity retained; `full-root=nil`, scope count `1`; TP reconciles 30 objects |

This checkpoint removes a duplicated candidate lifecycle. The partial-line slice below then narrows projection and layout for one stable owner shape; broader mounted paths can still index, project, lay out, and construct ownership beyond the final publication scopes. The next implementation work must generalize the affected layout/projection closure, not return to candidate helper micro-optimizations.

## Implemented checkpoint: partial-line scoped projection

Mounted span-patch now treats a partial-line owner as a set of existing parent slots rather than requiring the owner's spans to be contiguous. Each slot is shaped independently, while whole-line spans retain the contiguous-span safety proof. If span proof fails, the TP fallback reuses the already prepared surface root, node root, and object table instead of constructing a second surface context. Paint-only updates confirm the paint patch before span proof and text measurement, so they remain on the paint path.

After the span proof succeeds, the mounted producer uses TP's `tp-object-reuse-subtree` for the previously proven unchanged node-object subtree. The candidate still carries the complete output plan and its content-range attachments, but the unchanged subtree is excluded from TP's touched/reconcile set. This is a proof-driven reuse path, not a generic omission: if the candidate topology, output footprint, parent slots, roles, or overflow signature changes, the normal projection and reconciliation path remains available.

The latest evaluator and focused regression evidence are:

| Scenario | Scope evidence | Correctness evidence |
| --- | --- | --- |
| Mounted partial-row content update | `ensure-node-tree=0`, node-projection `3`, layout/fragment/ownership `4`, TP-object-preparation `5` | Elapsed `0.061124s`; `equal-including-properties`; mounted identity retained; `full-root=nil`, scope count `2`; `span-patch` |
| TP retained bookkeeping for the mounted partial-row path | `reconciled-objects=4`, `created-objects=0`, `removed-objects=0` | The proven unchanged subtree is retained without generic reconciliation; scoped TP transaction remains valid; no full-root fallback |
| TP retained bookkeeping for viewport resize | `reconciled-objects=30`, `created-objects=0`, `removed-objects=0` | The ordinary owner-rerender path remains correct and scoped, but its retained closure is not yet narrowed |

This is evidence that the affected-owner projection/layout boundary and retained-object bookkeeping can both be local for one partial-row update. It is not evidence that every structural, flex, overflow, viewport, or rollback-sensitive update has the same closure: the current viewport owner-rerender path still reconciles 30 objects.

## Implemented checkpoint: strict retained viewport reflow

Viewport changes now have a separate retained projection kind, `viewport-reflow`, for one deliberately narrow proof boundary. The candidate keeps the published root and reuses the retained TP node-object table; the producer reruns the complete viewport-sensitive layout and surface plan without calling `ensure-node-tree` or pretending the operation is a `span-patch`. TP then publishes the changed output through the retained root scope.

The planner authorizes this path only when all of the following hold: the owner plan is one root-owned geometry rerender; no dirty entry changes children; the root, node-key set, region-id set, and parent table are unchanged; neither the previous nor current runtime requires an ECSS cascade; no scroll state exists; the tree has no visible overflow; and the previous surface has a retained node-object table. Height-only and width-plus-height changes are covered by the same proof. Active stylesheet rules, inline inheritance, scroll state, visible overflow, and publication failure are explicit regression cases; each falls back or rolls back through the ordinary TP transaction.

The current evaluator and focused tests provide this checkpoint:

| Scenario | Scope evidence | Correctness evidence |
| --- | --- | --- |
| Viewport resize on the evaluator fixture | `node-projection=1`, `layout/fragment/ownership=7`, `TP-object-preparation=5`, `ensure-node-tree=0`, `reconciled-objects=4` | Fresh evaluator sample `0.030237s`; exact runtime output; root identity retained; `full-root=nil`, scope count `1`; one text operation |
| Height-only and both-axis resize | Retained `viewport-reflow`; no node-tree ensure calls | `:viewport-axes` is respectively `height` and `both`; output width and publication remain correct |
| Unsafe viewport cases | Active stylesheet, inline inheritance, scroll, and visible overflow use ordinary projection | Surface suite proves `39/39`; commit suite proves `4/4`; no unsafe case is mislabeled `viewport-reflow` |
| Failed viewport publication | TP publication failure is injected after candidate preparation | Surface revision, signal values, client state, Ebox state, and buffer text all remain on the old generation |

This closes the previously measured viewport over-computation for the evaluator fixture, but only inside this proof boundary. The broader architectural goal remains to establish a dependency-driven viewport damage closure for flex, scroll, cascade, overflow, and structural cases instead of widening this fast path speculatively.

## Implemented checkpoint: fixed-footprint copy-on-write region candidate

Mounted content-only updates now have one additional, deliberately narrow candidate path. When the update replaces string content in a box with a fixed numeric width, no content child node, no active cascade, and no scroll state, the incremental layer copies only the region owner and its ancestor path. The retained runtime tables are prepared with a local index delta, and the surface receives an explicit path-copied marker. This keeps candidate preparation in Ebox's planning layer while TP remains the owner of mounted identity, scoped publication, revision, and rollback.

The path is admitted only after the existing span-patch identity and footprint proof, plus a line-count preflight against the formatted replacement. A multiline or wrapping replacement is promoted to an ordinary private structural copy before it reaches the surface. The surface therefore never clears attachments on shared published nodes and never owns an emergency fallback copy.

| Scenario | Scope evidence | Correctness evidence |
| --- | --- | --- |
| Fixed-footprint mounted content update | Candidate preparation has no full `ebox--runtime-index`; the evaluator reports node-projection `1`, layout/fragment/ownership `4`, and TP-object-preparation `5`; the focused regression reports no second full structural copy | `equal-including-properties`; target mounted identity retained; `full-root=nil`, scope count `2`; strategy `span-patch`; evaluator and commit suites pass |
| Multiline or widened replacement | The line-count preflight rejects path sharing and promotes to a private candidate before surface projection | The rollback regression observes a private copy, injects publication failure, and verifies the old Ebox state, output, and published content remain unchanged |

This is a proof-bounded COW slice, not a general candidate policy. Structural, flex, overflow, cascade, scroll, viewport, and other footprint-changing updates continue to use the ordinary correctness path until their affected closure and rollback depth are separately proven.

## Current validation boundary

The declared evaluator passed on 2026-08-08: `make performance-evaluator` ran 39/39 surface tests and 4/4 commit tests, and all four scenarios passed their output, identity, scoped-publication, and non-overlapping-stage checks. The fixed-footprint mounted scenario preserved `equal-including-properties`, retained the target object, and published with `full-root=nil` and scope count `2`; the viewport scenario published with `full-root=nil`, scope count `1`, and `reconciled-objects=4`.

The broader `make check` baseline passed before the later COW checkpoint with 457/457 core tests, 15 grid tests, 4 commit tests, 32 surface tests, 4 visual-check tests, 11 package tests, 22 selector tests, 25 DSL tests, 60 flex tests, 4 documentation-contract tests, and 4 CI-contract tests. The current focused surface suite is 39/39, including fixed-footprint COW fallback, height/both-axis, and rollback cases. The earlier regressions are closed; the performance goal is not complete because broader viewport and mounted affected-closure proofs remain unfinished.

## Resolved validation regressions

The full-suite failures exposed two lifecycle-boundary bugs rather than invalid test expectations. First, `ebox--render-ephemeral-static` locally forced `ebox--defer-scroll-content-index` to nil, overriding the caller's deferred-scroll contract and adding the sentinel/lookahead line. The local override was removed so the caller owns that mode. Second, `ebox-incremental-surface-batch-root` returned the last batch candidate after the batch had been flushed. A following non-batch update then mutated the published root in place; old and new boxes aliased, the declarative dirty set became empty, and scoped publication received no retained owner. The accessor now returns a candidate only while the batch is active. The regressions pass without adding a scope fallback or changing expected behavior.

## Measurement and equivalence limits

- The start and end of `projection-start` are not yet defined. It is not safe to subtract style time from projection time to estimate non-style projection cost until candidate copy, style, layout, fragments, owner ranges, the ledger, identity reconciliation, retain, and publication have explicit boundaries.
- The count semantics for 1712 nodes, 1716 reconciled objects, 1262 style calls, and 301 calls on the 300-box fixture are not yet explained; root, wrapper, text-leaf, skipped-node, and cache-hit accounting must be made explicit.
- The earlier partial-row checkpoint reports `ensure-node-tree=0`, node-projection `3`, layout/fragment/ownership `4`, and TP `reconciled-objects=4`; the current fixed-footprint mounted evaluator reports node-projection `1`, layout/fragment/ownership `4`, and TP-object-preparation `5`, while the strict retained viewport checkpoint reports node-projection `1`, TP-object-preparation `5`, and `reconciled-objects=4`. Broader fallback paths may still report older whole-tree counts, so Ebox projection scope and TP retained bookkeeping must remain separate measurements.
- Historical baseline probes recorded length and SHA-256 without proving complete text properties. The current evaluator now uses `equal-including-properties` for the isolated and mounted comparisons; future scope changes must preserve that assertion.

## Ranked root causes

| Rank | Cause | Confidence | Evidence basis |
| --- | --- | ---: | --- |
| 1 | ECSS/reactive style cascade is eager and per-node | High | Dynamic update runs `ecss-compute-style` 1262 times for about 8.99s; pure render takes about 9.34s there; one visually inert rule triggers 301 ECSS computations |
| 2 | Projection/`ensure-node-tree` is often broader than the publication scope | High | The baseline probes showed 10.88s, 11.31s, and 11.56s projection-start intervals with 1712 `ensure-node-tree` calls; partial-row and strict viewport checkpoints now prove two safe closures with `ensure-node-tree=0`, while broader fallback paths remain unresolved |
| 3 | The `ebox-render` abstraction boundary is wrong | High | [ebox-layout.el:1444](../../ebox-layout.el#L1444) defaults to `tp-surface-materialize-string`; pure string callers still pay retained-surface projection cost |
| 4 | Candidate copy/index preparation remains broader than the publication scope outside proven paths | Medium | The duplicated region/scroll handoff is removed, and the fixed-footprint region path avoids a full runtime index; broader content, structural, and viewport paths still require their own closure proof |
| 5 | The retained TP boundary couples pure render, style, projection, and mounted update paths | Medium-high | Pure render entering the retained path is established; current data does not equate that coupling with the largest intrinsic TP identity/retain/publication cost |
| 6 | Ownership is represented and scanned at multiple layers | Medium-low | Fragments, owner ranges, TP plans, the property ledger, and text properties exist, but there is no independent timing for ownership construction/scanning |
| 7 | The underlying layout algorithm is universally slower | Low | Some no-stylesheet flex fixtures show current first mount at about 1.4–1.5s versus legacy at about 1.61–1.63s; “universally slower” is unsupported |

## What the current evidence does not establish

- `ebox-surface--project` and `tp-surface-materialize-string` are aggregate stages covering style, projection, fragments, ownership, and TP-related work; they cannot be treated as intrinsic TP cost.
- `property operations` counts (378 for content update and 361 for resize) are not timings; their performance contribution requires stage measurements.
- Legacy processing about 51 resize nodes suggests current scope may be too broad, but does not by itself prove that 51 is the correct minimum affected closure.
- Multiple ownership structures are a design risk worth testing, but the current evidence does not prove that they are all rescanned or that they can be safely merged.
- Full-tree candidate/index preparation may be a conservative correctness strategy; dependency, identity, and rollback evidence is needed to identify which remaining work is unnecessary. The duplicated copy/validation/reconciliation handoff has now been removed for isolated region and scroll candidates.

## Code-path evidence

The current retained data flow crosses these boundaries:

- [ebox-surface.el:535](../../ebox-surface.el#L535) builds a TP projection for the whole tree.
- [ebox-surface.el:712](../../ebox-surface.el#L712) copies the candidate root and [ebox-surface.el:725](../../ebox-surface.el#L725) reconciles identity.
- [ebox-surface.el:760](../../ebox-surface.el#L760) installs per-node style bindings and [ebox-surface.el:775](../../ebox-surface.el#L775) reads/applies computed style.
- [ebox-surface.el:785](../../ebox-surface.el#L785) recursively calls `tp-object-ensure` and `tp-object-retain`.
- [ebox-surface.el:1236](../../ebox-surface.el#L1236) constructs and attaches owner ranges from fragments.
- [ebox-surface.el:1269](../../ebox-surface.el#L1269) converts fragments into shared text leaves and a TP surface plan.
- [ebox-surface.el:1627](../../ebox-surface.el#L1627) decides whether the style-required path is active from stylesheet state, inline inheritance, and previous cascade state.
- [ebox-incremental.el:5235](../../ebox-incremental.el#L5235) prepares candidate runtime state, the runtime index, and the dirty set.
- [ebox-incremental.el:5933](../../ebox-incremental.el#L5933) has an isolated-candidate branch that reuses the prepared root, while the remaining owner plan determines downstream projection scope.
- [ebox.el:3486](../../ebox.el#L3486) publishes region updates through a surface-scoped TP publication.
- [ebox.el:3694](../../ebox.el#L3694) sends buffer rendering into surface mount; [ebox-surface.el:381](../../ebox-surface.el#L381) creates signals, a producer, and a TP transaction.

The corresponding legacy path is closer to “computation scope equals modification scope”:

- `emacs-box/ebox.el:7195` directly modifies the target region box and enters the local dirty/patch path.
- `emacs-box/ebox.el:7399` formats only the target content before applying the local patch.
- `emacs-box/ebox.el:7578` directly renders, inserts, and refreshes markers/spans.
- Legacy `ebox-style.el` mainly expands local properties and classifies dirty work; it has no equivalent current ECSS stylesheet/reactive per-node cascade.

## Evidence versus inference

### Evidence

- Current projection, style, candidate, and ownership stages account for most of the measured dynamic-update time.
- Current and legacy produce identical output lengths and SHA-256 values for content update, resize, and pure render comparisons.
- Current has a small final TP text-operation count and a small Ebox dirty-owner count despite large whole-tree prerequisite call counts.
- Stylesheet A/B produces per-node style/ECSS calls even when output is unchanged.
- The current code paths connect materialization, retained identity, style binding, and TP publication in one call chain.
- Current totals are nearly constant across three different operations while legacy varies substantially; this is corroboration for a fixed whole-tree cost, not an independent timing for one internal stage.
- The isolated candidate-handoff regression passes with one structural copy and zero duplicate validation/reconciliation; the earlier partial-row checkpoint reduced the mounted scenario to node-projection `3`, while the fixed-footprint COW checkpoint now measures node-projection `1` with layout/fragment/ownership `4` and TP-object-preparation `5`; the strict viewport checkpoint also measures node-projection `1`, TP-object-preparation `5`, and `reconciled-objects=4`.

### Inference

- The dominant problem is computation scope being larger than publication scope, not the efficiency of the final TP diff.
- Once a surface is cascade-required or needs retained identity, static and local paths still carry unnecessary whole-tree cost; style cascade and projection are the most directly measured bottlenecks.
- Pure render and mounted update are both affected by retained coupling but are not the same problem: pure render should bypass retained publication, while mounted update must preserve identity/rollback and narrow its computation closure.
- Optimizing `ecss-compute-style`, `tp-bind`, `ensure-node-tree`, or one helper in isolation will not change the fact that whole-tree work is scheduled on every path.
- Removing the duplicated candidate handoff improves the lifecycle boundary, and the partial-row slice demonstrates both affected layout/projection closure and proof-driven TP subtree reuse; the general mounted scope proof is still incomplete because viewport and broader structural paths remain wider.
- TP publication remains the necessary boundary for correctness, identity, revision, and rollback. The evidence supports delaying and narrowing entry into that boundary, not removing TP. Final publication is not the dominant observable bottleneck, but the independent contribution of retained TP construction remains unknown.

## High-level redesign direction

The target data flow should have two explicit ownership paths:

```text
Pure materialization
Source Tree
  -> style snapshot
  -> layout
  -> fragments
  -> propertized string

Mounted update
State mutation
  -> affected owner closure
  -> selective style/layout/paint
  -> reuse retained fragments/ranges
  -> TP publication
```

### 1. Separate pure materialization from retained publication

When the caller only needs a render string, `ebox-render` should not create a TP identity graph, reactive bindings, owner publication graph, or rollback participant. Only a mounted surface that needs stable identity, scope proof, revision, or rollback should enter the retained-publication boundary.

The split should occur at the publication boundary, after the single layout/fragment implementation, not before it. Pure and retained paths must share style snapshots, layout, and fragment generation to avoid two rendering semantics. If a product flow renders a preview and later mounts it, the promotion of ephemeral state to stable identity must be explicit, or a full attach must be accepted.

### 2. Make style/cascade a snapshot rather than default per-node reactive binding

Static inline style should enter a computed-style snapshot directly. Only nodes that truly depend on external dynamic values should install reactive bindings. Inherited-style invalidation should follow ancestor/subtree dependencies instead of making the entire tree recalculate whenever a surface is cascade-required.

Formal implementation requires a dependency-correctness gate first: for stylesheet and inline-inheritance triggers separately, record the actually read style inputs and compare the predicted affected set with a full recomputation, checking both under-invalidation and over-invalidation. Snapshotting alone does not create locality; a dependency graph that remains conservatively whole-tree will erase the benefit.

### 3. Use one ownership representation

The layout stage should produce a structured fragment/owner map, with unchanged fragments, ranges, and property state reusable. A local patch should not rescan the complete rendered string or reconstruct owner ranges, shared leaves, and the property ledger for unchanged nodes.

### 4. Use copy-on-write candidates

The fixed-footprint mounted content slice now implements this policy for one proven string replacement shape: it copies only the affected owner path and passes the sharing decision explicitly to the surface. Ordinary content/paint updates should follow this pattern only after the same proof exists. Structural, geometric, identity, or genuinely expanded rollback/scope-proof changes may construct a larger candidate. Rollback should remain at the publication boundary instead of making every update pay the full-tree isolation cost in advance.

The scoped candidate closure cannot be equated with a syntactic owner subtree; text growth, flex siblings, percentages, and container constraints can enlarge the layout-context closure. Copy-on-write also needs an explicit rollback depth and old-root lifetime policy so long editing sessions do not retain an unbounded number of generations.

### 5. Keep TP’s correctness responsibilities but narrow its entry condition

TP should continue to own live-buffer publication, diffing, revisions, stable retained identity, and rollback. The architectural repair is not to bypass TP; it is to keep pure render out of TP and give mounted updates only the affected structure and ownership.

## Problem separation and recommended order

| Stage | Problem to solve | Problem not to merge into it |
| --- | --- | --- |
| Pure render | String materialization should not create retained identity, bindings, or a publication graph | Mounted-update rollback and stable identity |
| Mounted content update | A dirty owner should not expand its computation closure to the whole tree | Viewport damage’s special geometric dependencies |
| Style cascade | Recompute only the actual affected style-dependency closure | TP property-publication tuning |
| Viewport resize | Establish a viewport damage region and affected layout closure | Treating legacy’s 51 nodes as the correct answer by default |
| Candidate/ownership | Reuse unchanged state after dependency closure is stable | Assuming every ownership structure is duplicated before timing it |

Recommended order:

1. P0a: Keep the evaluator and stage probes as the contract. The current probe confirms text-property-level equality and non-overlapping aggregate stages; candidate preparation is now separately measured, and the isolated handoff slice proves duplicate copy/validation/reconciliation can be removed without changing publication semantics.
2. P0b: Establish a style-dependency correctness gate covering stylesheet and inline inheritance separately; do not formally narrow style invalidation before the contract passes.
3. P0c: Done for the no-stylesheet/no-inline-inheritance slice: isolated pure materialization is implemented and passes the evaluator. Keep stylesheet-required pure rendering as a separate unresolved path until style snapshot dependencies are proven.
4. P0d: Run the full 2×2 experiment after the dependency gate and pure spike produce results, then decide the formal order of style snapshots, retained-path slimming, and scoped projection.
5. P1: Generalize the implemented partial-line scoped projection, fixed-footprint COW region candidate, strict retained viewport reflow, affected-layout closure, and proof-driven TP subtree reuse to stable content, flex, overflow, cascade, and rollback-sensitive paths. The fixed-footprint evaluator records node-projection `1`, layout/fragment/ownership `4`, and TP-object-preparation `5`; the strict viewport fixture records node-projection `1`, TP-object-preparation `5`, and TP `reconciled-objects=4`, while broader fallback paths remain unmeasured.
6. P1: Establish an independent damage region and affected layout closure for viewport resize beyond the strict proof subset, and reverse-engineer legacy’s local dirty/layout closure as a reference.
7. P2: Extend COW and ownership reuse beyond the fixed-footprint proof only after dependency, identity, scope-proof, and rollback contracts are stable, with an explicit rollback-depth/memory policy.
8. P2: Evaluate TP property operations last; do not make them the primary target while pre-publication costs dominate.

## Minimal discriminating experiment: 2×2 root-cause separation

This is the most valuable experiment before formal implementation, but it requires the read-only pure-materialization spike from P0c first. The two factors are retained-path usage and style-computation mode:

| | Reactive style | Style snapshot |
| --- | --- | --- |
| Retained path on | Current mounted baseline | Replace only style computation |
| Retained path off | Pure materialization baseline | Pure materialization plus snapshot |

Run the matrix on `dynamic-update-reference.ebox` and the 300-box stylesheet A/B fixture. Record total time, style calls, `ensure-node-tree` calls, reconciled objects, TP identity/retain counts, owner-range time, text/property operations, output length, and SHA-256.

- If disabling the retained path sharply lowers pure-render time, the `ebox-render` boundary is an important cause.
- If style calls remain 1262 with the retained path disabled, style cascade is an independent cause.
- If snapshots sharply lower style calls and total time, cascade invalidation is one of the main causes.
- If both changes still leave a large gap to legacy, continue splitting projection, candidate, ownership, and layout.

“Retained path off” is valid for pure materialization or a read-only experiment only; mounted updates must not remove stable identity, rollback, or scope proof.

The minimal execution sequence is: complete stage breakdown first; use read-tracking to validate stylesheet and inline-inheritance dependency closures; then run retained on/off with reactive style fixed; only after the dependency gate passes run the full four-cell matrix. This avoids a circular dependency between experiment infrastructure and formal redesign.

## Verification boundary for the target architecture

Before implementing the redesign, the target architecture should demonstrate these observable properties:

- Pure `ebox-render` does not create TP retained identity, surface bindings, or a publication graph.
- A content/paint update with no structural, geometric, or style-dependency change does not reproject the whole tree.
- An active stylesheet does not automatically imply that every node must recalculate; only affected cascade dependencies are invalidated.
- Local-update `ensure-node-tree`, reconciled-object, and style-call counts vary with the affected closure rather than remaining fixed at whole-tree scale.
- The computation scope of `owner-rerender`, `span-patch`, and `paint-patch` no longer expands to the whole tree by default.
- Structural changes, viewport geometry changes, and rollback-sensitive updates can still widen scope while preserving stable identity, TP transactions, and failure rollback.
- A retained `viewport-reflow` is selected only after topology, cascade, scroll, overflow, and owner-scope proofs pass; all other viewport changes use the ordinary correctness path.
- Scoped style must be equivalent to full recomputation for computed-style results (including inputs relevant to text properties) and must cover both stylesheet and inline-inheritance triggers.
- Scoped candidates must have an explicit affected-closure proof, old-root rollback semantics, and a bounded rollback/memory-retention policy.

## Unknowns and limits

- Legacy has no equivalent ECSS stylesheet/reactive cascade, so the full timing difference cannot yet be attributed one-to-one across cascade, layout, and ownership.
- Scroll offset, paint-only update, and batch update have not yet received equivalent stage breakdowns; the current conclusion is supported mainly by content update, viewport resize, pure render, and stylesheet A/B measurements.
- Which ownership/index structures can be merged without breaking stable identity, rollback, and TP scope proof requires follow-up read-only probes and contract tests.
- Style snapshots must cover dependency closures for theme, ancestors, selectors, viewport, faces, and other dynamic inputs; otherwise performance may be bought with incorrect rendering.
- Copy-on-write candidates depend on stable identity not relying on object addresses, immutable retained state before commit, and an old root/ledger that remains available for rollback.
- Content-update closure may include layout context and sibling nodes, not only the dirty owner subtree; legacy dirty propagation should be reverse-engineered as reference evidence.
- It is not yet known whether scope proof is check-driven or construction-driven. If whole-tree candidates currently provide safety by construction, scoped/COW candidates need an explicit proof mechanism.
- Absolute timings depend on local Emacs, display, and power state. This record uses relative stage structure and identical-output checks as the primary evidence.

## 2026-08-09 flex resize checkpoint

The exact public GUI evaluator for `ebox-playground/examples/flex-reference.ebox` was rerun after reverting an experimental viewport-dependent generic-cache override. The single `window-resize` action changed the preview viewport from `256` to `186` pixels and produced `1.202837s` end to end (`0.748485s` inside `ebox-rerender-buffer-with-context`). Preview mount, exactly one update, scoped publication, retained `viewport-reflow-mixed-scroll` (`reconciled=4`, `full-root=nil`, `scope-fallback=nil`), fresh-render visual/text-property equivalence, and the canvas background check all passed. The declared `0.5s` gate failed. This is the current acceptance result; it is not a millisecond-scale result.

The same-path stage probe is directional because advice adds measurement overhead, but it identifies the cost center: candidate rendering/materialization was about `0.38s` in the cleanest sample, while the root path made `142` `ebox--render-layout` calls. The probe saw `80` generic cache probes with only `2` hits and `78` no-context cases; fragment retention saw `8` hits, `37` rerenders, and `15` stores. TP snapshot/render/publication stages were not the dominant independent cost in that sample (`tp-text-snapshot` about `0.06s`); TP remains the required identity/publication/rollback boundary.

The Sol xhigh architecture review rejects widening generic viewport cacheability or changing the existing fragment key as a safe fix: retention lookup happens after child measurement and Flex reflow, and a hit cannot skip the parent reflow or final owner/range materialization. The owning boundary for the next optimization is therefore the structured `layout -> fragment/owner result` handoff. A reusable result must carry dimensions, owner/property runs, and its local containing-block/display signature; `ebox-surface` can then consume those runs directly without rescanning the complete propertized string. That larger slice must preserve candidate COW, rollback, scoped publication, and exact fresh-render equivalence.

Focused current checks remain useful but do not close the gate: Ebox Flex is `62/62`, Ebox surface is `49/49`, and the exact evaluator's correctness checks pass. The broader core run has two known failures in the already-dirty worktree (shrunk definite-item slot count and underfilled chrome mapline count), so they are recorded as regression gaps rather than silently attributed to this checkpoint. No temporary probe daemon or production cache override remains.

## Record boundary

This document fixes the root-cause model and high-level data-flow direction. It records five verified, narrow implementation slices but does not authorize benchmark-specific branches, timing hacks, relaxed performance gates, or fixture-specific cache paths. The remaining ownership and publication boundaries must be converted into verifiable design contracts and changed incrementally.
