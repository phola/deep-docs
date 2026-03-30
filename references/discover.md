# Phase 2: Discover

Spawn one sub-agent to explore the repository and generate specs.

## Sub-agent Task

```
Read {{DOCS_DIR}}/builder/interview-notes.md for user context.

Explore the repository at {{REPO_PATH}} thoroughly:

1. INVENTORY
   - Walk the entire file tree (excluding .git, node_modules, .venv, __pycache__, dist, build,
     plus any exclusions specified in {{DOCS_DIR}}/builder/interview-notes.md)
   - Catalogue: languages used, frameworks detected, package managers, config files
   - Count files and lines per directory to assess size

2. COMPONENT DETECTION
   Component boundaries MUST be determined by structural markers, not judgement:

   a) **Package-manager anchored** (preferred): Each directory containing a package.json,
      Cargo.toml, pyproject.toml, go.mod, *.csproj, pom.xml, or equivalent is ONE component.
      Do not merge multiple packages into one component. Do not split a single package into
      multiple components.

   b) **Monorepo workspaces**: If a root package.json/Cargo.toml/pnpm-workspace.yaml defines
      workspaces, enumerate them explicitly. Every workspace entry = one component.

   c) **Infrastructure-as-code**: Each directory with a Dockerfile, Bicep/ARM template,
      Terraform/CDKTF config, or CI pipeline definition is a component (unless it's already
      inside a package from rule a).

   d) **Fallback** (no package managers): Group by top-level directories that contain source
      files. Each top-level source directory = one component.

   For each component note: directory, SOURCE FILE COUNT (excluding tests, configs, assets),
   primary language, entry points, rough purpose.
   Detect dependencies between components (imports, shared modules, config references).

   DETERMINISM RULE: Run `find` or `ls` commands to enumerate package files. List every
   match. Do not rely on sampling or "exploration" — the inventory must be exhaustive.
   If re-run on the same repo state, the same components must be produced.

2b. COMPONENT GROUPING
   After detecting individual components, identify logical groups:

   a) **Path-based** (preferred): Components sharing a common parent directory form a group.
      Example: all packages under `workspaces/modules/content_library/` → "Content Library" group.
   
   b) **Naming convention**: Components sharing a consistent prefix form a group.
      Example: `cl_fun_api`, `cl_lib_db`, `cl_lib_models` → "Content Library" group.
   
   c) **Shared infrastructure**: Components that share infrastructure stacks
      (same Cosmos DB, same Service Bus topics) form a group.
   
   d) **Singleton groups**: If a group would contain only 1 component, do NOT create
      a group for it — the component stands alone.
   
   e) **Platform/shared groups**: Cross-cutting libraries and infrastructure that serve
      all modules may form a "Platform" or "Shared" group if there are ≥3 such components.

   For each group note: group name, group slug (hyphenated lowercase), member component
   slugs, shared path prefix (if any), brief purpose statement.

   DETERMINISM RULE: Groups must be derived from structural signals (paths, prefixes),
   not subjective judgement. Same repo state = same groups on every run.

3. EXISTING DOCS
   - Find all .md files, doc comments, docstrings, OpenAPI specs, type definitions
   - Assess quality: stub vs. substantive, current vs. stale
   - Note any existing architecture diagrams or schemas

4. STACK DETECTION
   - Language(s) and version constraints
   - Frameworks (web, data, ML, CLI)
   - Infrastructure (Docker, k8s, cloud provider, CI/CD)
   - Data stores (databases, file formats, APIs consumed)

OUTPUT two files:

{{DOCS_DIR}}/builder/specs/scope-and-goals.md
- JTBD statement
- Target codebase path and description
- What's in scope / out of scope (respect user exclusions from interview)
- Detected stack summary

{{DOCS_DIR}}/builder/specs/component-inventory.md
- Components in dependency order (foundations first)
- Use this table format:

| # | Component | Slug | Path | Source Files | Language | Purpose | Key Files | Dependencies |
|---|-----------|------|------|-------------|----------|---------|-----------|--------------|
| 1 | Shared Utils | shared-utils | src/shared | 8 | Python | Common helpers | utils.py, config.py | (none) |
| 2 | Auth | auth | src/auth | 34 | Python | Authentication | auth.py, models.py | shared-utils |

- Mark any components that are unclear or need deeper investigation

{{DOCS_DIR}}/builder/specs/component-groups.md
- Groups in dependency order
- Use this table format:

| # | Group | Slug | Path Prefix | Components | Purpose |
|---|-------|------|-------------|------------|---------|
| 1 | Content Library | content-library | workspaces/modules/content_library/ | cl-fun-api, cl-lib-db, cl-lib-models, ... | Media catalogue and metadata management |
| 2 | Shared Platform | shared-platform | workspaces/common/ | buzz-lib-db, buzz-lib-events, ... | Cross-cutting libraries used by all modules |

- If no meaningful groups detected (e.g., flat repo with <5 components), write
  the file with an empty table and a note: "No component groups detected — all
  components are standalone."

Do NOT write any documentation. Discovery only.
```

## User Touchpoint

After the sub-agent completes, present the generated specs to the user:
- Show the component inventory as a summary
- Show the component groups (if any)
- Ask: "Does this look right? Anything to add, remove, or reorganise?"
- Apply any corrections before proceeding

## Transition

Proceed to Phase 3: Calibrate.
