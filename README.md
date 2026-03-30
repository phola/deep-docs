# deep-docs

An [OpenClaw](https://github.com/openclaw/openclaw) agent skill that generates deep, multi-audience documentation for any code repository. It works bottom-up — reading every source file through iterative comprehension loops — and produces tiered output from executive summaries down to machine-readable inventories.

**Never modifies source code. Documents the as-is state only.**

## What it produces

| Tier | Audience | Content |
|------|----------|---------|
| **L1** | Leadership, stakeholders | 1-page executive summary, no code |
| **L2** | Product managers, BAs | Data flows, business rules, diagrams. 2–4 pages per component |
| **L2-Group** | Architects, tech leads | Subsystem overviews grouping related packages |
| **L3** | Developers | Architecture, patterns, gotchas, code references |
| **L4** | AI agents | Structured inventory — headings, tables, code blocks, no prose |

Plus Mermaid diagrams, a review report, and (in update mode) a changelog.

## Modes

| Mode | Use case |
|------|----------|
| `init` | Full documentation from scratch |
| `update` | Incremental update after code changes (diff-driven) |
| `history` | Retrospective changelog from git history |

## How it works

1. **Interview** — interactive Q&A to understand the repo  
2. **Discover** — walk the repo, build a component inventory  
3. **Calibrate** — auto-select profile (small / medium / large) based on repo size  
4. **Comprehend** — iterative deep-read of each component (3–7 loops depending on size)  
5. **Synthesise** — cross-component analysis, dependency mapping  
6. **Diagram** — generate Mermaid architecture and flow diagrams  
7. **Write** — produce L1–L4 docs per component, groups, and overviews  
8. **Review** — multi-pass review verifying docs against source code  
9. **Package** — optional mkdocs site generation  

Per-component phases are driven by a bash orchestrator (`scripts/orchestrate.sh`) that spawns one sub-agent per component — avoiding the "do 87 things" completion bias where LLMs sample and declare success.

## Quick start

Requires [OpenClaw](https://github.com/openclaw/openclaw) with an LLM provider configured (Anthropic recommended).

```bash
# Install as an OpenClaw skill
cp -r deep-docs ~/.openclaw/skills/deep-docs

# Full run
./scripts/orchestrate.sh all /path/to/repo /path/to/docs

# Individual phases (resume/retry)
./scripts/orchestrate.sh discover /path/to/repo /path/to/docs
./scripts/orchestrate.sh comprehend /path/to/repo /path/to/docs
./scripts/orchestrate.sh write /path/to/repo /path/to/docs
./scripts/orchestrate.sh review /path/to/repo /path/to/docs
```

Or just ask your OpenClaw agent: *"document this repo"* and it will pick up the skill automatically.

## Model routing

Two tiers balance quality and cost:

| Tier | Used for | Default |
|------|----------|---------|
| **Quality** | comprehend, synthesise, write, review pass 2+ | claude-opus-4-6 |
| **Economy** | discover, review pass 1, diagram | claude-sonnet-4-6 |

```bash
# Max quality — disable economy model
DEEP_DOCS_ECONOMY_MODEL="" ./scripts/orchestrate.sh all /path/to/repo /path/to/docs

# Custom economy model
DEEP_DOCS_ECONOMY_MODEL="openai/gpt-4o-mini" ./scripts/orchestrate.sh all /path/to/repo /path/to/docs
```

## Repo structure

```
SKILL.md                    # OpenClaw skill definition
scripts/orchestrate.sh      # Bash orchestrator — drives all phases
references/
  interview.md              # Interview phase guide
  discover.md               # Component discovery
  calibrate.md              # Auto-calibration profiles
  comprehend.md             # Iterative comprehension loops
  synthesise.md             # Cross-component synthesis
  diagram.md                # Mermaid diagram generation
  write.md                  # Doc writing (L1–L4)
  review.md                 # Multi-pass review
  package.md                # mkdocs packaging
  update.md                 # Incremental update mode
  history.md                # Retrospective changelog mode
  audience-tiers.md         # L1–L4 tier definitions
```

## Battle-tested

Successfully run against a 170+ component enterprise monorepo (~15,500 source files), producing 500+ documentation files across all tiers with automated review catching 519 issues.

## License

MIT
