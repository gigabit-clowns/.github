# Working on gigabit-clowns/.github

This is the organization's shared CI repository. It holds no product code: what
lives here is the reusable workflows and composite actions that every other
repository of the REX suite calls, plus the handful of scripts those actions
carry with them. Nothing here is built, and nothing here is released.

Keep this file true. When a change makes something here wrong or missing — a
new composite, a moved script, an input that changed meaning, an invariant that
stopped holding — update it in the same pull request that causes it. A pull
request that leaves this document stale is an incomplete pull request.

## The thing to understand first

Callers reference this repository at `@main`, not at a tag:

```yaml
uses: gigabit-clowns/.github/.github/composites/restore-ccache@main
```

There is no staging, no release and no version to hold back on. A commit
merged here is in force everywhere on the next run, and when it is wrong the
failure surfaces in the calling repository, where nothing points back at the
commit that caused it. That is why this repository lints itself harder than
its size suggests, and why a change here is reviewed against every caller
rather than on its own.

`renovate.json` disables updates for `gigabit-clowns/.github` itself, since a
caller pinned to `@main` would otherwise be offered an endless stream of SHA
bumps.

## Layout

| Path | Holds |
|---|---|
| `.github/workflows/` | Reusable workflows, `workflow_call` only, plus this repository's own `lint.yml` |
| `.github/composites/` | The composite actions, one directory per action |
| `.github/composites/*/`*`.sh` | Shell that an action sources rather than inlines |
| `.github/scripts/` | Files an action copies into the caller's workspace |
| `.github/requirements-lint.txt` | The pinned linters `lint.yml` installs |
| `conf/` | Linter configuration that is not read from the repository root |
| `.yamllint.yml` | yamllint's configuration, which it only finds at the root |

A composite nested under another is not automatically private. `run-ctest`
dispatches to `run-ctest/internal` and `run-ctest/memcheck`, and neither is
called from outside; `run-ctest/coverage-report` sits in the same directory but
is called directly by `rexlib`. Only `run-ctest/internal` says which it is in
its description, and the other three should grow the same sentence.

`.github/scripts/` is deliberately not fetched over the network. An action
reads its script from `$GITHUB_ACTION_PATH/../../../scripts/`, which is the
checkout the runner already made of this repository, so the script and the
action that uses it are always the same commit.

## The workflows

| Workflow | Called on | Does |
|---|---|---|
| `clean-up-caches.yml` | A caller's `workflow_run` or dispatch | Deletes superseded, dead or excess Actions caches |
| `keep-caches-warm.yml` | A caller's schedule | Touches caches so the seven-day expiry does not take them |
| `release.yml` | A caller's release trigger | Tags from `VERSION` and opens a GitHub release from `CHANGELOG.md` |
| `lint.yml` | Push and pull request **here** | This repository's own CI |

`lint.yml` is the only one that is not `workflow_call`. Every other workflow
runs in the repository that calls it, and has no effect on a push to this one.

## The caches

Three composites cooperate, and they only work in pairs. `restore-ccache`
leaves `CCACHE_RESTORED_AT` in the environment and `save-ccache` reads it to
evict everything the job did not touch; `restore-fetched` leaves `FETCHED_KEY`
and `FETCHED_HIT` and `save-fetched` reads those to decide whether to store at
all. A save without its restore fails the step on purpose rather than writing
a cache built from nothing.

Facts that the code cannot state and that a change here has to respect:

- A GitHub cache entry cannot be overwritten. Every run leaves a new entry, and
  only the newest of a prefix is ever restored — which is what makes
  `select_superseded` in `caches.sh` safe: it strips the tail that makes a key
  unique (a timestamp, a 40-character commit SHA, a run id) and keeps the
  newest of each group. Under `fetched-`, a 64-character content hash counts as
  part of the group instead, because there the newest hash is the version the
  repository has moved to.
- A cache path is hashed exactly as written, so it has to carry the runner's
  own separator. Both `save-ccache` and `keep-caches-warm` spell the Windows
  path with a backslash for that reason, and a restore that spells it
  differently silently never hits.
- A merged pull request's `refs/pull/N/merge` is deleted with it, so a cache
  left on one can never be restored again. `select_dead` removes those first,
  before anything live is weighed.
- Over the 10 GiB ceiling GitHub evicts by last access, which takes a branch's
  caches before a pull request's — a pull request keeps touching its own.
  `select_headroom` therefore frees from pull request refs only, and never from
  `refs/heads/`.
- `live_refs` failing is not the same as "no ref exists". An empty answer would
  mark every cache dead, so it returns non-zero instead.
- A lookup with `lookup-only` is enough to reset the seven-day expiry clock,
  and downloads nothing. That is the whole of `keep-caches-warm`.
- The `headroom` job of `clean-up-caches.yml` runs under `if: !cancelled()`
  because each event fires one scope and skips the other, and a skipped job
  would skip whatever needs it.

`caches.sh` is sourced, not executed, so that every step of the action reports
in the same shape. It reads `GH_TOKEN` and `GH_REPO` from the environment, the
way `gh` does.

## Coverage

`run-ctest/coverage-report` produces one report per matrix cell and
`merge-cpp-coverage-reports` merges them, and the two are a pair: each report
is written against the workspace of the runner that produced it, and the job
that merges them has a different one. `normalize-paths` replaces that path with
`GITHUB_WORKSPACE` as a literal placeholder, and the merge puts its own path
back.

Getting the pair wrong fails quietly, which is the danger. A report produced
with `normalize-paths` off and then merged, or produced with it on and then
read where it was produced, resolves onto no source file and reads as zero
coverage rather than as an error.

MSVC is the exception in every step of this: OpenCppCoverage writes Cobertura
rather than lcov, so the normalization is done by
`.github/scripts/coverage/msvc_path_normalization.py` instead of by `sed`.

## Continuous integration

`lint.yml`, on pull requests, on pushes to `main` that touch something other
than documentation, and on demand. A second push to the same ref cancels the
run in flight. One job, and each step names the tool it runs:

| Step | Covers |
|---|---|
| `yamllint --strict` | Every YAML file in the repository |
| `actionlint` | The workflows, including shellcheck over their `run:` blocks |
| `check-jsonschema --builtin-schema vendor.github-actions` | Every composite `action.yml` |
| `check-jsonschema --builtin-schema vendor.renovate` | `renovate.json` |
| `shellcheck --severity=style` | The `.sh` files beside the actions |
| `ruff check` | `.github/scripts/**/*.py` |

The division between the second and third rows is not a preference. actionlint
understands workflows only — a composite `action.yml` reads to it as a workflow
with `jobs` and `on` missing — so the composites are validated against the
published action schema instead. Nothing else in the job reads a composite as
YAML, which is why `yamllint` runs first: a file that does not parse at all
reads to every later step as an empty one.

The linters are pinned in `.github/requirements-lint.txt` so that a linter
release cannot turn `main` red on its own. actionlint is pinned by tag and
digest together; Renovate reads the tag and updates the digest.

Actions are pinned by digest everywhere, under a 14-day minimum release age
that security advisories skip. The `# v7` after a digest is not decoration —
Renovate reads it — so it stays.

CodeQL scans this repository for the `actions` language, on every push and
weekly, and that is why there is no workflow here for it: it is configured
through GitHub's default setup rather than committed as a file, unlike the
sibling repositories, which each carry a `codeql-actions.yml` of their own.
`gh api repos/gigabit-clowns/.github/code-scanning/default-setup` is where to
read the current configuration.

## Code conventions

YAML is two spaces. A sequence under a key may be indented or not, and each
file keeps to one; `.yamllint.yml` asks for consistency within a file, not
agreement between files.

Shell is `bash`, and steps lean on GitHub's default for it, which already
carries `-e` and `-o pipefail`. Only `clean-up-caches/action.yml` sets
`set -euo pipefail` of its own, for the `-u` the default leaves off; a step
that reads a variable which may be unset should do the same.

Python is tabs in the existing script, and `conf/ruff.toml` carries the same ruleset
the other repositories of the suite lint under, so a script can move between
them without being rewritten.

An action input is a string by the time a step reads it, whatever it is spelled
as in the metadata. Write `default: "true"`, never `default: true`, and compare
against `'true'` — the schema check rejects the bare boolean.

An action that declares no `inputs:` cannot read `inputs.anything`; the
expression evaluates to the empty string and every condition built on it is
silently false. Nothing in CI catches this, so it is worth a second look
whenever a composite is split.

### Comments

As few as possible, and none at all wherever that is possible. A comment says
**what**, never **why**. The why belongs in the commit message and the pull
request, where it can be read against the change that motivated it instead of
rotting in a file that moved on without it.

And the what only when the code does not already say it. If a reader
understands the line without the comment, the comment does not go in. A banner
announcing that the steps come next, a note restating the step name above it,
an explanation of what a well-known action does — all of that is text to be
kept true for no gain.

The rule covers every file: a workflow step whose name already says what it
runs does not also need a paragraph above it. What does stay is the thing that
is not a comment at all — a step's `name`, an action's `description`, an
input's `description`, a docstring, the `# v7` a digest pin carries for
Renovate — and, where a contract has to be written down somewhere, this file
is where it goes.

## Invariants — do not violate

- Callers use `@main`. A commit merged here is in force everywhere at once.
- `restore-ccache` and `save-ccache` are a pair, and so are `restore-fetched`
  and `save-fetched`. A save without its restore fails the step.
- A cache path carries the runner's own separator, because the path is hashed
  as written.
- `select_headroom` frees from pull request refs only, never from
  `refs/heads/`.
- `run-ctest/coverage-report` with `normalize-paths` on must be followed by
  `merge-cpp-coverage-reports`, and with it off must not be.
- An action reads its scripts from `$GITHUB_ACTION_PATH`, never over the
  network.
- Every `uses:` is pinned by digest, with its version in a trailing comment.
- An action input is a string. Quote it in `default:` and compare it as one.
