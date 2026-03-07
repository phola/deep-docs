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
   - Identify logical components (not just directories): services, pipelines, libraries,
     CLI tools, APIs, shared modules, infrastructure config
   - For each component note: directory, SOURCE FILE COUNT (excluding tests, configs, assets),
     primary language, entry points, rough purpose
   - Detect dependencies between components (imports, shared modules, config references)

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

Do NOT write any documentation. Discovery only.
```

## User Touchpoint

After the sub-agent completes, present the generated specs to the user:
- Show the component inventory as a summary
- Ask: "Does this look right? Anything to add, remove, or reorganise?"
- Apply any corrections before proceeding

## Transition

Proceed to Phase 3: Calibrate.
