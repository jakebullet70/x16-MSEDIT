# EDIT - TODO

- **Low RAM: 278 bytes free** (v0.9.238, top at $9DEA, `memtop` $9F00). Was 36 B at the start of the
  2026-07-20 session. Recovered by: folding the four ".ovl not found" literals into one
  `flash_no_ovl()` helper (41 B); trimming `UNDO_DEPTH` 24 -> 20 (62 B, `SES_VER` bumped to 2 with
  it); aliasing `workbuf` onto `edoc.linebuf` (**+177 B net**); and folding `prompt_str`'s two bool
  parameters into one `flags` byte (39 B - one ubyte parameter costs less than two bools plus the
  local it replaced).
  The `workbuf` alias is SHIPPED, and its first failure is now explained. It was tried once before
  (v0.9.215) and backed out: the real fault was that the BASLOAD error line `berr` used to alias
  `workbuf`, and it is scraped in `start()` BEFORE `restore_run_state()` (which `load_file`s the
  documents) and printed AFTER it - so `load_file` overwrote it through the new alias while
  `berr_len` stayed non-zero, and the bar printed 80 bytes of the last loaded line. `berr` now owns
  its 80 bytes, hence +177 rather than +256. The RULE for anything parked in `workbuf` is at its
  declaration: it must not stay live across an Open, a Save or a session restore.
  prog8 has no call stack, so every sub-local is permanently
  allocated: a single new `uword` local can fail the build. The proven moves, by yield: push text or
  labels into a banked overlay (menus.ovl freed ~1.1 KB), move a fixed-size buffer into the CLIP_BANK
  window (fksnap + startdir freed 181 B), alias a buffer whose lifetime cannot overlap another's
  (`workbuf` = `edoc.linebuf` 256 B, `bakname` = `workbuf` inside act_make_backup). A fifth, cheapest
  of all: put a whole FEATURE inside an overlay whose key loop already runs in-bank - the input
  history below cost zero. The CLIP_BANK window is full to $AAC2 — read the SLACK WARNING at the
  FKSNAP_ADDR constant before putting anything there.
  Remaining candidates, largest first:
  - **Merge `draw_text_row` (edit.p8:845) into `draw_wrapped_row` (edit.p8:926)** — ~500-600 B. The
    two are ~85% identical; `draw_text_row(r)` is expressible as
    `draw_wrapped_row(r, top_line+r, left_col, left_col+textw, true)`. Watch the `uword` vs `ubyte`
    `srcidx` and the wrapped path's extra end-of-segment cursor case. It also fixes a latent bug: the
    wrapped path hardcodes `$b0` for the current-line band instead of reading `theme.CB_BAND`. Hot
    path — check redraw speed after.
  - **Move cold prose into an overlay behind one `ovl_msg(id)`** — ~400 B of the 1044 B of interned
    strings is user-facing text that never runs in a hot loop. The three session messages
    (edit.p8:563-571, 96 B) are the easiest: startup-only, and that orchestration already lives in
    misc.ovl. Guard the missing-overlay case — you cannot use the overlay to report the overlay is
    missing.
  - **Move the syntax keyword blobs (syntax.p8:32-34, 453 B) into a bank** — costs a bank switch per
    token in `classify()`. Cheaper variant with no speed cost: length-prefix the table and drop the
    space separators, worth ~40-60 B.
  - Do NOT alias `savebuf` onto `workbuf` — act_make_backup (edit.p8:2429) copies `bakname`
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

- **UP/DOWN input history at the Find / Replace prompts (v0.9.238)** — 8 entries per prompt, each
  with its own ring, re-entering a term promotes it instead of duplicating it. Cost **zero low RAM**:
  the ring (2 x 8 x 41 B) and all its code live in misc.ovl, which is possible only because
  `ovl_prompt`'s key loop already runs in-bank, so recall is in-place on the status row and nothing
  has to repaint the text area. (XFMGR2 pays 51 B for the same feature because its recall is a POPUP
  over the panes, which main has to redraw - port the idea, not the shape.) The category rides in
  the caller's `flags` byte, bits 4-7. Deliberately NOT included: disk persistence (session-only -
  `.his` files would mean more installed files and the host-FS overwrite hazard), Save As (the name
  comes from the document; the picker is the way back to an old one), and Go-to-line. Find now opens
  EMPTY unless text was selected, since the old term is one UP away.
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
