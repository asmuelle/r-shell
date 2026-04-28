# Rust Context Engineering Tools

Checked against current docs on April 21, 2026, the highest-ROI Rust CLI stack is not a giant toolbox. It is a small set of commands that make the edit-search-run-verify loop brutally short and predictable.

## Practical Stack

Use this as the default stack for a serious Rust repo, especially if you want AI or agent workflows to stay disciplined.

### Build and correctness core

- `cargo check`, `cargo fmt`, `cargo clippy`, `cargo fix`, `cargo tree`, `cargo doc`
- `cargo-hack` — feature combinatorics (agents add feature gates but rarely test all combinations)
- `cargo-limit` — suppress cascading errors; agents waste tokens "fixing" errors that aren't real

### Dependency discipline

- `cargo-audit` — known vulnerabilities
- `cargo-deny` — license compliance, duplicate detection, banned crates
- `cargo-udeps` — find unused dependencies (agents accumulate dead deps faster than humans)
- `cargo-edit` — `cargo add`/`rm`/`upgrade`; never let an agent hand-edit `Cargo.toml`

### Testing and coverage

- `cargo-nextest` — faster, more reliable, better isolation
- `insta` — snapshot testing; diff-based assertions are agent-friendly
- `cargo-llvm-cov` — branch-level coverage in CI; agents that skip branches produce false confidence
- `cargo-public-api` — `cargo public-api diff` tells an agent exactly which public contracts changed

### Search and navigation

- `ripgrep`, `fd`, `fzf`, `zoxide`
- `cargo-modules` — renders the crate module tree as a graph or table

### Command surface and environment

- `just` — stable repo verbs
- `direnv` — remove hidden environment state
- `bacon` — continuous feedback for Rust-first repos
- `watchexec` — custom watch loops for mixed repos

### Inspection and performance

- `cargo-expand`, `cargo metadata` plus `jq`, `cargo-bloat`, `tokio-console`
- `hyperfine` — honest benchmarks
- `sccache`, `mold` — build acceleration

### Review ergonomics

- `delta` — diffs worth reading
- `cargo-binstall` — fast tool installation

### Why this specific stack

- `cargo check`, `fmt`, `clippy`, and `fix` compress the correctness loop.
- `cargo-hack` catches feature-gate bugs, which are among the hardest for agents to notice.
- `cargo-audit` and `cargo-deny` prevent agents from building on vulnerable, unlicensed, or duplicated dependencies.
- `cargo-udeps` catches dep rot before it accumulates.
- `cargo-edit` prevents malformed manifests and accidental version bumps from hand-edits.
- `nextest` improves speed, reliability, and test isolation.
- `insta` replaces hand-written assertions with diff review — less ambiguity, faster decision.
- `cargo-llvm-cov` makes test gaps visible at branch level.
- `cargo-public-api` makes semver impact mechanical instead of judgmental.
- `cargo-limit` stops cascading-error noise from wasting agent tokens.
- `rg`, `fd`, `fzf`, and `zoxide` remove navigation friction.
- `cargo-modules` lets an agent see the crate structure before reading individual files.
- `just` turns tribal knowledge into stable repo verbs.
- `direnv` removes hidden environment state.
- `bacon` and `watchexec` make feedback continuous instead of manual.
- `cargo-expand`, `cargo metadata`, and `cargo-bloat` expose system structure.
- `sccache` and `mold` keep the edit-verify loop fast in large workspaces.
- `hyperfine` keeps performance discussions honest.
- `delta` makes diffs easier to reason about.
- `cargo-binstall` lowers adoption friction for Rust CLI tools.

## Recommended Adoption Order

If standardizing a new Rust team, adopt in this order:

1. `rg`, `fd`, `fzf`
2. `cargo check`, `cargo fmt`, `cargo clippy`, `cargo nextest`
3. `just`, `direnv`
4. `bacon`
5. `cargo-edit`, `cargo-expand`, `cargo-tree`, `cargo-modules`
6. `cargo-deny`, `cargo-audit`, `cargo-udeps`
7. `insta`, `cargo-llvm-cov`, `cargo-public-api`
8. `cargo-hack`, `cargo-limit`, `hyperfine`, `delta`, `sccache`

## Minimal Repo Command Surface

A clean command surface is what makes a repo friendly to both humans and agents. A minimal `justfile` should usually collapse to something like this:

```just
check:
  cargo check --workspace --all-targets

lint:
  cargo clippy --workspace --all-targets --all-features -- -D warnings

fix:
  cargo clippy --workspace --all-targets --all-features --fix --allow-dirty
  cargo fmt --all

test:
  cargo nextest run
  cargo test --doc

watch:
  bacon

fmt:
  cargo fmt --all

doc:
  cargo doc --no-deps --document-private-items

audit:
  cargo audit
  cargo deny check

prune:
  cargo udeps

hack:
  cargo hack check --each-feature

pr-check:
  just fix
  just lint
  just check
  just hack
  just test
  just audit

deps:
  cargo tree -d
```

For CI or reproducible validation, prefer `--frozen` or `--locked` to prevent `Cargo.lock` mutation during the check/lint/test loop.

That setup is good for vibe coding because it removes ambiguity. The agent does not need to guess how to validate a change. It calls `just pr-check` and the repo answers consistently across all dimensions.

## Why This Accelerates Vibe Coding

The main bottleneck in AI-assisted development is usually not code generation. It is bad context, hidden state, and fuzzy validation.

- Good CLI tools make context explicit. `cargo metadata`, `cargo tree`, `cargo-modules`, `rg`, and `git diff` expose the real shape of the system.
- Good CLI tools make validation cheap. If the loop from edit to signal is under 10 seconds, people and agents both make better decisions.
- Good CLI tools make workflows composable. Text in, text out, stable exit codes, JSON when needed.
- Good CLI tools reduce prompt bloat. Instead of explaining the repo every turn, define verbs once in `justfile`, config, and CI.
- Good CLI tools are agent-friendly because they are deterministic. GUIs hide state; CLIs expose it.

For context engineering specifically, every repeated judgment should become either a command, a config file, or a machine-readable artifact.

## Non-Tool Practices That Improve Agent Discipline

Tools are necessary but not sufficient. These conventions reduce ambiguity for agents with zero runtime cost.

### Module-level documentation as machine-greppable contracts

Every `mod.rs` or top-of-file comment should expose a standard section set that agents can grep before editing:

```rust
//! # Overview:
//! # Invariants:
//! # Safety:        (for unsafe code)
//! # Errors:        (error types this module produces or propagates)
//! # Dependencies:  (modules this one talks to, not crate deps)
```

An agent that greps `# Invariants:` before modifying a module makes fewer assumption errors.

### Semantic versioning as machine-checkable contract

- Mark all public enums in library crates `#[non_exhaustive]` — prevents agents from writing exhaustive matches that break silently when another PR adds a variant.
- Run `cargo public-api diff` in CI on every PR branch. The agent sees exactly which public contracts it changed and decides whether to bump semver or revert.

### Type-state API design

Prefer builders over large constructor signatures:

```rust
// Hard for agents to diff and compose in parallel sessions
Connection::new(host, port, user, key, timeout, retries, keepalive, compression);

// Easy for agents — each field is its own diff chunk
ConnectionBuilder::new(host).user(user).key(path).timeout(secs).build()?;
```

Smaller, composable types mean smaller diffs and fewer merge conflicts from parallel agent sessions.

### Architecture Decision Records (`docs/adr/`)

When an agent makes a structural decision — e.g., "why `Arc<RwLock<HashMap>>` instead of a channel?" — record it:

```
docs/adr/001-connection-manager-concurrency-model.md
```

Future agents can grep ADRs instead of reinventing or silently undoing decisions.

### Pre-commit guard

A pre-commit hook that runs `just check && just lint` catches problems before an agent pushes a broken branch. The hook itself is one line of shell; the leverage is enormous.

```bash
#!/bin/sh
just check && just lint
```

## Tools built by asmuelle

These tools — all published on [crates.io](https://crates.io/users/asmuelle) — close gaps that still lack mature Unixy CLI solutions. They exist as real crates but are early-stage and still being battle-tested.

- `cargo-context` — builds an optimal AI context pack from `git diff`, `cargo metadata`, recent errors, entry points, and test targets
- `cargo-impact` — predicts blast radius of a change and selects likely affected tests, commands, docs, and runtime surfaces
- `diff-risk` — semantic risk scoring for diffs, especially around API contracts, async boundaries, serde or schema changes, auth, and concurrency
- `spec-drift` — compares code against `README`, `AGENTS.md`, examples, tests, and CI commands, then reports where stated repo reality diverges from actual behavior
