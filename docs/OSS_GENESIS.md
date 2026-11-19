# Open-source repository genesis

This repository's history starts at one **sanitized import commit**: a clean
`git archive` snapshot of the private development repository's `main` at
`1bc5985cc9614c93f9a46261f9b8e0d9c87a7229`. No earlier history, branch, pull
request reference or CI log was carried over. Commits use a GitHub noreply
identity.

## Privacy redactions in the import

Only these changes were made to the snapshot before the first commit:

| File | Redaction |
|---|---|
| `docs/HOT_SWITCH_FEASIBILITY_GATE.md` | a developer's local user-profile path → `%USERPROFILE%` (3 places) |
| `docs/PROJECT_STATUS.md` | a link to a private CI run → a note that the run lives in the private history |
| `AGENTS.md` | names of unrelated private projects → "all other, unrelated product repositories" (the isolation rule is unchanged) |
| `docs/README_V3_升级说明.txt` | names of unrelated private projects → generic wording |
| `CLAUDE.md` §6 | developer-machine environment notes → a rule to keep such notes local |

The import tree is `8dd01f4f772e95fbcbb140d3850c8814a4d71f3e`.

## LR-14 scope gate in a fresh history

The LR-14 scope gate (`tests/validate-local-router-lr14-scope.ps1`) normally
identifies its historical slice as "the commit that introduced the validator and
that commit's parent". In this repository that commit is the root and has no
parent, and the private slice (`c36c7e5..e3d60a8`) does not exist here.

**Genesis mode** handles exactly that shape and nothing else. All of these must
hold:

- the history has exactly one root commit;
- that root is the commit that introduced the validator;
- the root's tree equals the pinned, reviewed import tree above.

In genesis mode the gate pins the historical LR-14 slice's 28-file list (which
can't be re-read here) and still requires every commit of a reviewed delta to
belong to a registered slice whose range resolves in this repository.

Any other root, or a second unrelated root, keeps the original fail-closed
behaviour. Registrations from the private history stay in the file as a record;
their SHAs don't resolve here, so they never authorize anything.
`tests/validate-oss-genesis.ps1` exercises these cases on real clones.

## Other history-dependent validators

Four more validators proved their reviews with private commit objects. They
share one genesis detector, `tests/shared/oss-genesis.ps1`, which carries the
same tree pin as the LR-14 gate (`validate-oss-genesis.ps1` asserts the two
pins are equal). The detector only accepts a history with exactly one root
commit whose tree equals the pinned import tree.

In every other history, including the private one, these validators behave
exactly as before. In the verified genesis history, the private evidence is
replaced as follows:

| Validator | Original evidence (private objects) | Genesis evidence (bound to the genesis root's objects) |
|---|---|---|
| FIX5 file authorization §1 | the six FIX5 commits exist and the chain tail (or its patch-id equivalents) is an ancestor of HEAD | the base and chain pins equal the recorded review (original SHAs, stable patch-ids, source-main equivalents); every reviewed file's blob at the genesis root **and** at HEAD equals the recorded reviewed blob |
| FIX5 file authorization §2 | each file is still owned by a commit carrying its reviewed patch | each file's last change is the genesis root itself (no later commit touched it) and it is the reviewed blob; the marker, pin and mutation proofs (§2–§4) are unchanged |
| FIX5 final integration §1 | the exact six-commit range, linear topology, and ancestry of HEAD | the same pin and blob checks as above; every member has a recorded source-main equivalent |
| FIX5 final integration §13 | protected installer files byte-identical across the FIX5 range; the range touches no protected file, installer/skill/docs or binary | the pinned 37-file range list must match its pinned digest, and those predicates are re-evaluated on it; byte-identity of the protected files is the recorded result of the private gate |
| FIX5 regression (cases A–N) | re-cuts private PR2/PR3 and the FIX5 chain | GA–GN on real fixtures of this history: post-genesis change, change-and-restore, missing surface, wrong order, wrong pin, forged evidence, wrong baseline pin, forged root, second root, merge as owner, conflict determinism, deleted review, removed marker, unauthorized file |
| HS1B-RB1 §6 | the earlier reviewed `router-codex-cli.ps1` blob from commit `072ac4c` | rebuilt from the genesis root's blob plus the reviewed reverse patch `tests/fixtures/oss-genesis/hs1b-rb1-earlier-router-codex-cli.patch`; it must equal the recorded blob `05664423e8fb` and the pin carried by the genesis root's own `protected-file-scope.ps1` |

Two things can't be reproduced here, and both are stated, not hidden:

- the acceptance of a re-cut private chain (regression cases B and N);
- the live byte-identity of the protected files across the private FIX5 range.

Both are recorded results of the private review.

## Follow-up work from the private repository

Work not yet in the private `main` (release composition and installation
identity verification) is migrated as ordinary pull requests against this
repository: the same file changes are re-applied, re-validated and registered
with SHAs from this history. No private commit is imported.
