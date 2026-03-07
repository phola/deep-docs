# Phase 3: Calibrate

Automated phase — no sub-agent needed. The orchestrating agent reads the discovery output
and selects a calibration profile.

## Inputs

- `{{DOCS_DIR}}/builder/specs/component-inventory.md`
- File count and component count from discover phase

## Profiles

### Small (< 20 source files, ≤ 5 components)

3 comprehension loops (see [comprehend.md](comprehend.md) SMALL PROFILE for details).
Synthesise: 1 pass. Write: single sub-agent for all components.

### Medium (20-100 source files, 6-15 components)

5 comprehension loops (see [comprehend.md](comprehend.md) MEDIUM PROFILE for details).
Synthesise: 2 passes. Write: one sub-agent per component (sequential).

### Large (100+ source files, 15+ components)

7 comprehension loops (see [comprehend.md](comprehend.md) LARGE PROFILE for details).
Synthesise: 3 passes. Write: per component, parallel where no dependency conflict.

**Parallel grouping algorithm:** Group components into dependency levels.
Level 0 = components with no dependencies on other project components.
Level 1 = components depending only on Level 0 components. Etc.
All components at the same level can run in parallel. Process levels sequentially.
Record the grouping in calibration.md as:

```
## Parallel Groups
Level 0 (no dependencies): shared-utils, config
Level 1: auth, database
Level 2: api, worker
```

### Empty or Trivial Repo

If <3 source files or 0 detectable components: inform the user that the repo appears
too small for deep-docs. Offer to write a single comprehensive README instead.

### Conflicting Signals

When file count and component count suggest different profiles (e.g. 30 files but only
3 components), use the **larger** profile.

## Output

Write selected profile to `{{DOCS_DIR}}/builder/calibration.md`:
- Profile name (small/medium/large)
- File count, component count
- Number of comprehension loops
- Number of synthesise passes
- Sub-agent strategy for write phase
- Ordered component list for comprehension (dependency order)

## Transition

Inform user which profile was selected and why. Proceed to Phase 4: Comprehend.
