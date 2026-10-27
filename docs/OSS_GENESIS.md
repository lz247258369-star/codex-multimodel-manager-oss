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

## Follow-up work from the private repository

Work not yet in the private `main` (release composition and installation
identity verification) is migrated as ordinary pull requests against this
repository: the same file changes are re-applied, re-validated and registered
with SHAs from this history. No private commit is imported.
