# Daily RFVP updater

`RFVP daily update` checks `xmoezzz/rfvp`'s **main commit SHA**, not releases,
versions or tags, once a day at **01:23 UTC**. GitHub schedules are best-effort
and can be delayed. The workflow must be merged onto `main` before the schedule
can run. Public repositories may have schedules disabled after 60 days without
activity. A configuration PR passing tests is not deployment evidence.

## What it does

1. Run the updater's offline tests.
2. Compare the public upstream main SHA with the `packages/rfvp` gitlink on main.
   Refuse rewritten/non-forward history and fail on API/network errors.
3. Scan **all open PRs**, including other base branches, with paginated actual
   file lists and actual head gitlinks. An existing same-SHA update or any human
   RFVP/bridge adaptation blocks a duplicate. Mixed-submodule PRs count too.
   Titles and branch names are not used as the duplicate-detection source.
4. For a new candidate, run the unchanged host overlay, `cargo check --locked`,
   provider build and CTest regressions on a fresh hosted macOS runner. Check
   that the upstream checkout remains clean and the bridge lockfile is unchanged.
5. Re-read upstream, main and all relevant PRs before publication. If the plan
   changed during verification, stop and wait for a later run. A separate job
   writes only the RFVP gitlink through GitHub's Git Data API and opens a draft.
   A failed verification is disclosed in that draft with the run link; it never
   triggers an automatic code adaptation, merge or release.

There is no mutation when the upstream SHA is already covered. An existing bot
PR can advance only if it remains a draft, has no auto-merge, still has exactly
one changed path (`packages/rfvp`), and its head SHA, target pin and main base
match the bot's recorded state. A digest also protects human title/body edits. A human commit or body-state change causes the
bot to leave it alone. If main advances, the bot leaves the existing PR for
manual reconciliation rather than rebasing it. Ref updates are fast-forward
only; no force-push, close or delete operations exist.

Branches use `rfvp-update/<initial-base-prefix>-<initial-target-prefix>`. They
are not reset or deleted after a merge. A branch left behind by a partial API
failure is reported for manual inspection; the bot does not guess whether a
write succeeded or erase it. Full SHAs are used in all API operations.

The general submodule updater excludes RFVP in push, all-submodule and explicit
manual modes. This prevents the old gitlink-only workflow from bypassing RFVP's
compatibility and deduplication checks. Other submodules retain their old flow.

## Credentials and trust boundary

The workflow uses **only the ephemeral GITHUB_TOKEN**, never `GH_PAT`, deploy
keys, a new App, or a new credential. Discovery/verification use read-only
permissions. Only the isolated publisher has `contents: write` and
`pull-requests: write`, the same rights already declared by the general updater.
The publisher is reachable only from a main-branch scheduled/manual run; it
checks out the immutable trusted main base and executes no upstream code. It
consumes no artifacts or outputs created by the candidate runner, only the
trusted discovery plan and GitHub's verification job result.

All updater jobs disable cache access (`cache-mode: none`), particularly because
a scheduled candidate build would otherwise have main-scoped cache access.
Checkouts do not persist credentials. Candidate builds use only public RFVP
sources, with no private submodule checkout, signing credentials, artifact
uploads, or privileged runner. Passing tests establishes limited compatibility,
not that arbitrary upstream build scripts are trustworthy.

All four full-product Build jobs skip `rfvp-update/` PR/ref names and
`github-actions[bot]`-authored PRs, including a later human-triggered synchronize.
The ref guard also covers manual Build dispatch on bot branches. The independent
RFVP provider checks remain available. Do not remove these guards merely to make
a bot PR's product checks green: review/adapt the candidate on a human branch
before granting it the existing full-product CI trust, or review and merge it
manually. Main builds retain their existing behavior after a reviewed merge.

GitHub may require a maintainer to approve workflows on GITHUB_TOKEN-created PRs.
The daily workflow's own secretless verification runs before publication and its
result is linked in the PR. No PAT fallback is attempted. If GitHub rejects PR
creation because the repository's “Allow GitHub Actions to create and approve
pull requests” setting is disabled, the run fails with that API error. A maintainer
must decide whether to change that setting; this change does not alter settings,
install an App, or grant persistent access.

## Verification and operation

Local checks:

```sh
python3 -m unittest discover -s tests/python -p test_submodule_updates.py -v
python3 -m unittest discover -s tests/python -p test_rfvp_update.py -v
git diff --check
```

PR events run only offline updater tests, never discovery or publication. After
review and merge, a maintainer may run “RFVP daily update” on **main** to check
live deduplication and credential policy. If an adaptation PR already covers
upstream, a successful “skip” is expected. Confirm a scheduled run after merge
before calling the daily bot deployed. Existing external monitoring is unaffected
and should not be disabled until its owner explicitly chooses to migrate.

A blocked adaptation, failed provider run, changed main base, disabled schedule,
or partial publication needs human attention. Inspect the run summary and logs;
no repeated PR comments or duplicate drafts are produced for an unchanged SHA.
Tests do not certify full application builds, Apple packaging, commercial-game
playback, audio/video synchronization or save compatibility beyond the existing
standalone regression suite. The bot preserves the existing overlay and lockfile;
API changes and compatibility fixes still require code review and adaptation.

A failed-verification draft for an unchanged SHA is deduplicated, not retried by
new daily/manual runs. For a transient failure, a maintainer can dispatch the
secretless “RFVP provider” workflow on that bot branch and review the new result;
the updater's original failure record remains historical. Take over/reconcile
an orphan branch manually after inspecting the exact failed API operation.
GitHub's ref update and PR metadata update are separate API operations, not one
transaction. The updater rechecks immediately around the non-forced ref update
and stops if it observes changes; coordinate manual takeover rather than editing
the bot branch concurrently with publication.

References:
- [GitHub token triggering and approval behavior](https://docs.github.com/en/actions/concepts/security/github_token)
- [Cache access controls](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
- [Scheduled workflow constraints](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
