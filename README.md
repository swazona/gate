# swazona-gate

Deterministic Tier-D code review over a pull request's diff, published as a
GitHub check run named **`swazona-gate`**, plus customer-verifiable evidence
for every run:

- a **check-run summary** on the check itself,
- **one PR comment** kept current across pushes, carrying the head sha and
  attempt in a hidden marker. The comment is informational, never
  authoritative — the check run and the evidence (both bound to the head
  sha) are the authority, and the comment names the commit it belongs to,
  so stale content is recognisable. A stale writer never overwrites a newer
  head, and concurrent first posts converge by deleting our own higher-id
  duplicate. One race is accepted (B12): GitHub offers no conditional PATCH
  for issue comments, so a stale writer can still win the final PATCH;
  this is a stated limitation,
- a **`swazona-evidence.json` workflow artifact**, attested with GitHub
  artifact attestations on public repositories when enabled.

The evidence states what was found, why, how to reproduce it, the confidence,
the refuter's verdict, what was **not** checked, and the trust metrics. The
check reads success only after the evidence is written, re-verified against
the gate result byte-for-byte, published, and read back from GitHub as sent.
Any inconsistency rewrites the check run to `swazona-gate: evidence check
failed` — no verdict is ever published without evidence that binds to it.

## Usage

```yaml
permissions:
  contents: read
  checks: write
  pull-requests: write
  id-token: write        # needed for attestation
  attestations: write    # needed for attestation

steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  - uses: swazona/gate@<40-hex commit sha> # v1.0.0
    with:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `repo-dir` | `${{ github.workspace }}` | Repository working directory to diff. |
| `rules` | `''` | Repo-relative path to a custom Tier-D rule registry, read from the **base** commit. |
| `base` / `head` | the PR's base/head sha | The refs to diff. |
| `github-token` | `${{ github.token }}` | Needs `checks: write`. |
| `license` | `''` | Swazona license key. If set, always verified; invalid fails the check closed. Optional on github.com for public repositories (see Free tier). |
| `dry-run` | `'false'` | Publish nothing; write payloads under the run directory instead. |
| `mode` | `'shadow'` | `shadow` reports findings as neutral; `enforce` fails the check on blocking findings. |
| `block-on-model-findings` | `'false'` | `true`: a run whose model tiers could not execute concludes failure. |
| `finder-model` / `refuter-model` | `''` | Model ids, e.g. `anthropic/claude-haiku-4-5-20251001`. Empty disables the model tiers. |
| `finder-price` / `refuter-price` | `''` | USD per million input tokens, for the cost ledger. |
| `max-model-usd` | `'2.00'` | Hard per-run model spend cap. |
| `anthropic-api-key` / `openai-api-key` | `''` | Provider keys (pass via secrets; never echoed). |
| `anthropic-base-url` / `openai-base-url` | `''` | Optional provider endpoint overrides. |
| `attest` | `'auto'` | `auto`: attest when the repository is public and `id-token: write` is granted, else record why attestation is unavailable and continue. `true`: required — a failed attestation fails the run. `false`: skip. |
| `pr-number` | `${{ github.event.pull_request.number }}` | Where the evidence comment goes; empty disables it. |
| `comment-author` | `github-actions[bot]` | Bot login whose marker comment is kept current. |

## Outputs

| Output | Meaning |
|---|---|
| `run-dir` | Per-invocation directory (`$RUNNER_TEMP/swazona-gate-<invocation-id>`) holding `result.json`, `swazona-evidence.json`, `attestation.json` and dry-run sidecars. |
| `invocation-id` | `<run id>-<attempt>-<32 hex>`; binds every artifact of this run. |
| `evidence-sha256` | sha256 of `swazona-evidence.json` — the attestation subject digest. |

## Permissions

`contents: read`, `checks: write`, `pull-requests: write` (the comment),
`id-token: write` and `attestations: write` (attestation). Omit the last two
only with `attest: 'false'`.

## Free tier

On github.com, public repositories run the gate free, whoever owns them:
leave `license` unset. The Action confirms that the repository is public
with the GitHub API using `github-token` (the default token with
`contents: read` is enough); if it cannot confirm it, the check fails and
asks for a license. For a pull request from a fork, the repository that
runs the workflow decides. Private and internal repositories, including
private repositories on a personal account, and GitHub Enterprise Server
need a license.

## Outcomes

- **success** — evidence verified and published; verdict was clean or findings were advisory-only.
- **failure** — blocking findings (enforce mode), the gate's own inputs rejected, or an evidence-verification failure. Fail-closed: an unreadable ruleset, an unobtainable diff, or a GitHub API error is never a pass.
- **neutral** — shadow mode with blocking findings, or a pre-verdict infrastructure failure in shadow mode.

## Model providers

With model tiers enabled the runner contacts the configured providers
(`api.anthropic.com` / `api.openai.com` or the `*-base-url` overrides) for the
finder and refuter calls. Without keys or model ids the model tiers do not run
and the evidence's Not-checked section says so.

## Verdict cache

The Action has steps that restore and save a verdict cache with
`actions/cache`, but in this release they never store an entry, so every
run executes its configured model tiers from scratch. In blocking mode
(`block-on-model-findings: 'true'`), `swazona-gate` never reads or writes
the cache at all.

## Attestation on private repositories

Artifact attestation does work on private repositories with GitHub Enterprise
Cloud — but the probe cannot see the plan, so `attest: auto` skips private
and internal repositories either way: the evidence records `attestation
unavailable (repository visibility: private)` and the run continues. On
Enterprise Cloud, set `attest: 'true'` to require attestation.

## Verifying evidence yourself

```sh
gh attestation verify swazona-evidence.json -R <owner>/<repo>
```

No Swazona service or account is required: the artifact is JSON, its digest is
recorded in the check summary and in the attestation, and the schema ships
under `schema/`.

## Fork pull requests

Forks receive no secrets, so the model tiers record themselves as not run.
GitHub also gives fork `pull_request` tokens no `checks: write`, so the check
run cannot be published; run this Action on `pull_request` only where the
token can write checks.

## Dependency pinning

Every `uses:` here is pinned to a full 40-hex commit SHA. Tags move; a SHA
can't. Dependabot updates the pins with review like any dependency bump.
