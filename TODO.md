# EDIT - TODO

- **Low RAM: 108 bytes free** (v0.9.220, top at $9E94, `memtop` $9F00). Was 36 B; recovered by folding
  the four ".ovl not found" literals into one `flash_no_ovl()` helper (41 B) and trimming `UNDO_DEPTH`
  24 -> 20 (62 B, `SES_VER` bumped to 2 with it). A third change - aliasing `workbuf` onto
  `edoc.linebuf` for 256 B - is **reverted and unproven**; see the warning at the `workbuf`
  declaration. It was reverted while chasing a Replace bug that turned out to be unrelated (see Done),
  so the alias was never actually cleared or convicted. The one real datum against it is that Make
  Backup repainted the whole screen; that was never re-tested after the Replace fix and may well have
  been the same class of bug. Worth retrying carefully - it is the single largest win left.
  prog8 has no call stack, so every sub-local is permanently
  allocated: a single new `uword` local can fail the build. The proven moves, by yield: push text or
  labels into a banked overlay (menus.ovl freed ~1.1 KB), move a fixed-size buffer into the CLIP_BANK
  window (fksnap + startdir freed 181 B), alias a buffer whose lifetime cannot overlap another's
  (`workbuf` = `edoc.linebuf` 256 B, `berr` = `workbuf` 80 B). The CLIP_BANK window is full to $AAC2 —
  read the SLACK WARNING at the FKSNAP_ADDR constant before putting anything there.
  Remaining candidates, largest first:
  - **Merge `draw_text_row` (edit.p8:837) into `draw_wrapped_row` (edit.p8:918)** — ~500-600 B. The
    two are ~85% identical; `draw_text_row(r)` is expressible as
    `draw_wrapped_row(r, top_line+r, left_col, left_col+textw, true)`. Watch the `uword` vs `ubyte`
    `srcidx` and the wrapped path's extra end-of-segment cursor case. It also fixes a latent bug: the
    wrapped path hardcodes `$b0` for the current-line band instead of reading `theme.CB_BAND`. Hot
    path — check redraw speed after.
  - **Move cold prose into an overlay behind one `ovl_msg(id)`** — ~400 B of the 1044 B of interned
    strings is user-facing text that never runs in a hot loop. The three session messages
    (edit.p8:557-561, 96 B) are the easiest: startup-only, and that orchestration already lives in
    misc.ovl. Guard the missing-overlay case — you cannot use the overlay to report the overlay is
    missing.
  - **Move the syntax keyword blobs (syntax.p8:32-34, 453 B) into a bank** — costs a bank switch per
    token in `classify()`. Cheaper variant with no speed cost: length-prefix the table and drop the
    space separators, worth ~40-60 B.
  - Do NOT alias `savebuf` onto `workbuf` — act_make_backup (edit.p8:2419) copies `bakname`
    (which *is* `workbuf`) into `savebuf`, so those two are live at the same instant.
- **PRG2BASLOAD: auto-quote DATA items containing spaces** — BASLOAD lexes DATA content as identifiers,
  so `DATA HELLO WORLD` becomes `DATA HELLOWORLD` (see docs/basload-findings.md). The converter emits a
  `REM TODO` and leaves it. Better: split the DATA content on commas and wrap any unquoted item that
  holds a space in quotes. Careful with items that are already quoted, and with numeric items — quoting
  a number changes what `READ N` does.
- **BASLOAD token picker popup** — a popup listing the BASLOAD control-code tokens (`{CLR}`, `{HOME}`,
  `{RVS ON}`, colour names, ...) so they can be picked and inserted at the cursor instead of typed from
  memory. The supported set is enumerated in the BASLOAD docs — mirror that list, don't invent one.
  Text-heavy, so build it as a banked overlay rather than in low RAM.
- **Escape-char popup** — same idea for the `/x`-style escape form (e.g. hex/`\x` character escapes):
  a pick-and-insert popup for the characters that are awkward to type. Shares the overlay with the
  token picker if both get built.
- **Ctrl+Shift+PgUp/PgDn to select to the file ends** — small follow-on to the Ctrl+PgUp/PgDn jump
  added in v0.9.211. `ed_doc_jump` does not touch the selection today, matching plain PgUp/PgDn.
  Shift+Home / Shift+End (keycodes 147 / 132) already extend on the line, so the pattern exists; the
  open question is whether the X16 keymap delivers a distinguishable Ctrl+Shift+PgUp at all.

## Not worth building

- **PRG2BASLOAD: 2-character variable collisions.** Noted only so it does not get "discovered" and
  designed a third time. BASIC 2.0 uses the first 2 characters of a name and BASLOAD uses 64, so in
  theory `VAR1`/`VAR2` are one variable before conversion and two after. In practice people writing
  Commodore BASIC knew the 2-char rule and named accordingly, so real programs do not contain the
  collision. Do not spend a detector on it.

## Done

- **Replace blanked the match line (v0.9.219).** Long-standing bug, not from the RAM work.
  `draw_text_row` renders `cur_row` from `editbuf` and every other row from the document, so
  `editbuf` is the display source for the cursor line. `act_replace` set `cur_row = found_row` for
  the interactive Y/N highlight without reloading `editbuf`, so the match line was painted with the
  PREVIOUS cursor line's contents - blank whenever that line was empty or shorter. Display-only:
  `cur_dirty` was false, nothing was committed, and the tail `edoc.load` repaired it. Find was
  unaffected because `goto_found()` already reloads. Rule: never assign `cur_row` by hand - call
  `goto_row()` / `goto_found()`, or do the `edoc.load(cur_row, &editbuf)` + `cur_dirty = false` pair.
- Ctrl+PgUp / Ctrl+PgDn jump to top / bottom of file (v0.9.211) — this was filed as Ctrl+Home/End;
  PgUp/PgDn avoids the Ctrl+End-vs-Ctrl+D keycode-4 ambiguity that made the original risky.
- "ABC" doc indicator moved from the status bar to the menu bar, flush right (v0.9.208).
- File > Close / Close All (v0.9.207). Open-file picker filter + delete.
- Installer: verified on build 200 — all 11 files copied including prg2basload.prg, a REINSTALL
  preserved edit.cfg, `^/ED` launches from any folder, help .md files display in the viewer. The
  run-from-inside-/msedit guard was closed as won't-test rather than tested: INSTALL.PRG is not one
  of the installed FILES, so it never lands in /msedit and the case does not arise in normal use.
