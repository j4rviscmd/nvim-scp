---
name: release
description: Recommend the next semver tag from commits since the latest tag, ask for confirmation, then create and push the tag. GitHub Release is created automatically by release.yml. Use when the user says "release", "version up", "tag", or asks for the next version.
---

# release

Recommend the next semver version, confirm with the user, create and push a tag.
No version file, no CHANGELOG — the tag is the version. `release.yml` creates the
GitHub Release with auto-generated notes on tag push.

## Steps

1. Sync tags and find the latest one:

   <!-- Constraint: recommend only v* tags — .github/workflows/release.yml
   triggers on `v*` alone, so a tag with any other prefix silently creates
   no GitHub Release. -->

   ```bash
   git fetch origin --tags
   git tag --list 'v*' --sort=-v:refname | head -1
   ```

   No tags yet → recommend `v0.1.0`.

2. List commits since the latest tag:

   ```bash
   git log --oneline <latest-tag>..origin/main
   ```

3. Recommend the next version (0.x semantics — breaking changes bump MINOR):

   | Change since last tag | Bump |
   |---|---|
   | Breaking change | minor (e.g. v0.1.0 → v0.2.0) |
   | `feat:` | minor |
   | `fix:` / `docs:` / `chore:` / `ci:` only | patch |
   | No commits since tag | recommend skipping |

4. Ask the user yes/no via AskUserQuestion with the recommendation
   (e.g. "v0.2.0 — feat: mkdir from picker"). On "no", stop.

5. Create an annotated tag on `origin/main` and push it:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z" origin/main
   git push origin vX.Y.Z
   ```

   Push only the tag — never push to `main` directly.

6. Report: tag pushed, GitHub Release will be created by the `release` workflow.
