# CLAUDE.md

## Language

- Code, comments, docs, commit messages, PR/issue bodies: English
    - `.language` = `english`

## Formatting

- Do not format lua files by hand
    - stylua via `stylua.toml`; CI (`.github/workflows/ci.yml`) enforces
      stylua + selene, no need to run them locally

## Testing & verification

- No test framework. Verification is a manual smoke test against a real host
  (the `host` from `setup()`)
    - Checklist: README.md "Development"
- The agent cannot verify transfers on its own; a human runs the smoke test

## Implementation constraints

- `telescope.nvim` is the only dependency — do not add new ones
- Run external commands (`ssh`/`scp`) async via `vim.system`, args as a list
  (avoids shell quoting issues)
- Windows is first-class: gate local path conversion on `vim.fn.has("win32")`
- Transfer flow: README.md "Flow"; future work: README.md "Roadmap"
