# EDIT - TODO

- **Ctrl+Home / Ctrl+End jump to top / bottom of file** — today keycode 19 (Home) and 4 (End) both act
  on the current line only ([edit.p8:4261-4262](SRC/edit.p8#L4261-L4262)). Add the Ctrl variants: top of
  file sets `cur_row = 0`, bottom sets `cur_row = edoc.line_count - 1` and the cursor to that line's end,
  both resetting `cur_col` and scrolling the viewport so the cursor is visible, then a full text redraw
  (a jump is almost never a one-line scroll, so the VRAM-scroll path does not apply). Copy the shape of
  the Left-arrow case at [edit.p8:4255-4260](SRC/edit.p8#L4255-L4260), which already branches on
  `g_mod & MOD_CTRL`. Three things to check: (1) **End is keycode 4, which is also Ctrl+D** — the known
  Ctrl+letter ambiguity, so verify in the emulator that Ctrl+End actually arrives as 4 with `MOD_CTRL`
  set and is not swallowed as Ctrl+D; (2) word-wrap mode has its own parallel renderer, so the jump has
  to land correctly there too; (3) decide whether Ctrl+Shift+Home/End should extend the selection to the
  file ends, matching the existing Shift+Home/Shift+End behaviour on 147/132.
- **Open-file popup: filter + delete** — in the Open file picker, add (1) a filter toggle that shows
  only BASLOAD source (the `has_basic_ext` set: `.bas` / `.basl` / `.bl` / `.bas.txt`), and (2) a Delete
  key that removes the highlighted file from disk (with a Y/N confirm) and drops it from the list. Both
  act on the existing `filelist` records in FLIST_BANK; delete uses `diskio.delete` + `void diskio.status()`
  (clear the channel), then re-reads the directory or compacts the list in place.
- **Installer: the run-from-inside-/msedit case is still untested** — install.p8 is meant to skip the
  copy when the folder it was launched from IS the install folder, rather than copy each file onto
  itself and truncate it. It does not arise in normal use (INSTALL.PRG is not one of the installed
  FILES, so it never lands in /msedit), which is exactly why it has never been hit: reproducing it
  means deliberately copying the release into /MSEDIT and running it there. Worth doing once, since
  the failure mode is destroying the install rather than merely looking wrong.
  Everything else was verified on build 200: all 11 files copied including prg2basload.prg, a
  REINSTALL preserved the existing edit.cfg, `^/ED` launches from any folder, and the help .md files
  display in the viewer.
- **File menu: Close file / Close all** — close the current document (and a Close-all that walks every
  open doc), each prompting to save when the doc is dirty. Reuse the existing `confirm_save` flash
  prompt rather than a new popup. Decide what "closed" means for the 3-doc model: leave the slot empty
  and switch to the next occupied one, or reset the slot to an untitled empty doc. Close-all should stop
  on the first Esc/cancel instead of ploughing through the rest.
- **Move the "ABC" doc indicator from the footer to the header** — the three-cell active-document
  indicator lives in `draw_status` ([edit.p8:1361-1371](SRC/edit.p8#L1361-L1371)), between the INS/OVR
  flag and the centred "Total lines" block. Move it up to the menu bar (`draw_menubar`), which has free
  space on the right. Carry the colouring rules across unchanged: active slot in `theme.CB_MENUSEL`,
  an inactive-but-dirty slot in `ACCEL_FG` against the bar background — noting the header uses a
  different bar colour, so the `(theme.CB_BAR & $f0) | ...` expression has to be rebased on the menu
  bar's own colour or the dirty cell will sit on the wrong background. Then reclaim the gap in
  `draw_status`: `col` is still advanced past the indicator and feeds the `lstart > col + 1` guard that
  decides whether "Total lines" is drawn at all, so drop those `col +=` steps rather than leaving them.
  Also check the header repaints on a slot switch and on the first edit that sets `slot_modified` —
  today those paths call `draw_status()`, not the menu-bar draw.
- **PRG2BASLOAD: 2-character variable collisions — NOT WORTH BUILDING.** Noted only so it does not get
  "discovered" and designed a third time. BASIC 2.0 uses the first 2 characters of a name and BASLOAD
  uses 64, so in theory `VAR1`/`VAR2` are one variable before conversion and two after. In practice
  people writing Commodore BASIC knew the 2-char rule and named accordingly, so real programs do not
  contain the collision. Do not spend a detector on it.
- **PRG2BASLOAD: auto-quote DATA items containing spaces** — BASLOAD lexes DATA content as identifiers,
  so `DATA HELLO WORLD` becomes `DATA HELLOWORLD` (see docs/basload-findings.md). The converter emits a
  `REM TODO` and leaves it. Better: split the DATA content on commas and wrap any unquoted item that
  holds a space in quotes. Careful with items that are already quoted, and with numeric items — quoting
  a number changes what `READ N` does.
- **BASLOAD token picker popup** — a popup listing the BASLOAD control-code tokens (`{CLR}`, `{HOME}`,
  `{RVS ON}`, colour names, ...) so they can be picked and inserted at the cursor instead of typed from
  memory. The supported set is enumerated in the BASLOAD docs — mirror that list, don't invent one.
- **Escape-char popup** — same idea for the `/x`-style escape form (e.g. hex/`\x` character escapes):
  a pick-and-insert popup for the characters that are awkward to type.
