---
name: release
description: Recommend the next semver version from commits since the latest tag, ask for confirmation, update CHANGELOG.md, and open a release/vX.Y.Z PR. Merging it makes tag-release.yml create the tag and GitHub Release automatically. Use when the user says "release", "version up", "tag", or asks for the next version.
---

# release

Recommend the next semver version, confirm with the user, update CHANGELOG.md,
and open a `release/vX.Y.Z` PR. No version file — the tag is the version.
Merging the PR makes `tag-release.yml` create the tag and the GitHub Release
via the API (`release.yml` only serves hand-pushed `v*` tags).

## Steps

1. Sync tags and find the latest one:

   <!-- Constraint: recommend only v* tags — the v* pattern is a contract
   shared by release.yml and tag-release.yml, so a tag with any other prefix
   silently creates no GitHub Release. -->

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

5. On a new branch named `release/vX.Y.Z` off `origin/main` (the branch name
   is the version source for `tag-release.yml`), add the
   `## [vX.Y.Z] - <today>` section to CHANGELOG.md (Keep a Changelog
   categories: Added / Fixed / Changed), commit as `chore: release vX.Y.Z`,
   push, and open a PR to main.

   Never push to `main` directly.

6. After the PR merges, report: `tag-release.yml` creates the `vX.Y.Z` tag on
   the merge commit and the GitHub Release with auto-generated notes — no
   manual tag step.
