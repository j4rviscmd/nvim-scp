# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.2.0] - 2026-08-26

### Added

- Path jump in Telescope pickers: paste a path (8+ chars landing at once) to
  jump immediately without `<CR>`, or type one and hit `<CR>` — absolute,
  `~`-anchored, or relative to the current dir, in both browsers. A file
  target opens its parent with the file preselected; bad paths error and
  reopen the picker where it was.

### Fixed

- Remote paths resolve to their absolute form on listing
  (`cd <path> && pwd`), so `../` climbs above `~` too.
