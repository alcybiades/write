# Automated testing

- Run regression tests with `make test`; the test executables compile with
  `WRITE_TESTING` and use isolated preferences and recovery drafts.
- For automated UI checks, launch a separate app instance with `--test-mode`
  (for example, `open -na /Applications/Write.app --args --test-mode`), or set
  `WRITE_TEST_MODE=1` when launching the executable. Never create scratch tabs
  or type test content into the user's normal Write session.
- Use temporary fixture files for edits. Test mode isolates app state, but
  explicitly opened files still save to their supplied paths.
- A preview intended for the user to use with their own documents may launch
  normally; do not use that session for automated edits.
