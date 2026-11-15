# Final fix wave
Tests first. RED: `18 failed, 149 passed` (after adding new tests, before code). GREEN: `167 passed` (`control/.venv/bin/python -m pytest control -q`).
1. passphrase: normalize uses `[ \t\r\n-]`, matches encodes with surrogateescape, rejects empty stored/non-str. Note: a real raw 0xFF Bearer byte never reaches our view: HA's own auth middleware raises in jwt decode first (HA core behaviour, not fixable here). So the test drives `HelloView._auth` directly with a `\udcff` header: 401 and lockout counts.
2. `_coerce` in runtime by catalog type (number/boolean/text/enum), mismatch -> None; contract README sentence added; entity ends `unknown`.
3. `wait=inf` clamps to MAX_WAIT_S; test proves hold times with patched MAX.
4. Lockout: success is a no-op, 1024 IP cap (oldest unlocked evicted, locks kept), prune max once/s, double prune removed.
5. `DeviceRuntime.close()` called on unload; setup wrapped so a failed setup pops the runtime.
6. Hello rejects min>max and strings > 200 chars.
7. At most 5 failed-ack warnings per apply_state plus a summary.
8. const.py docstring already true; confirmed.
9. Package README updated (sensitive diagnostics, MAC in registry, transient 404/409 during reload; device_name/send_serial verified in the kindle-agent plan).

## Restore deleted view tests
Cause: an editing mishap of mine. When rewriting `test_commands_wait_clamped` I replaced the file with `s[:a]+new`, which dropped everything after it (9 tests). Restored verbatim from 001698a (lines 128-end). Renamed my new helper `_hello_with` -> `_hello_mut` because the restored file already defines `_hello_with`.
Collected test ids diffed 001698a vs now (whole `control/` tree, including contract tests): the only id gone is `tests/test_lockout.py::test_success_resets_counter`, intentionally replaced by `test_success_does_not_reset_failures`.
Command `control/.venv/bin/python -m pytest control -q`: `182 passed`.
