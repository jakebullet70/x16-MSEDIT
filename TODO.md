# EDIT - TODO

- **Low RAM: 535 bytes free** (v0.9.285, `memtop` $9F00). Freed ~290 B by moving 21 cold status-bar
  messages (session/save/backup/search/clipboard/undo toasts + the modal Y/N prompts) into menus.ovl
  behind `msg_text` ($A009); main's `msg(id)` copies one into `msgbuf` and hands it to
  notify/put_str_at unchanged. NOTE: they went to menus.ovl, NOT misc.ovl - misc.ovl is FULL (adding
  them there overflowed its 8 KB bank by ~220 B). Before that: the in-window wrap-scroll fix (the
  how==0 two-row repaint, below) cost ~240 B; it was funded by moving the top MENU BAR drawing
  (draw_menubar + draw_filename_title, ~600 B of cold screen-painting) out into menus.ovl behind the
  `mnu_bar` jmptable entry ($A006). See the Done entries and [[edit-banked-overlays]]. Earlier the
  wrap-scroll VRAM fast path was funded by moving the ~450 B of BASIC syntax keyword tables OUT of low
  RAM into misc.ovl (see [[edit-banked-overlays]]
  / the syntax-kw note): syntax.p8 now holds 3 pointers into MISC_BANK, set at startup via the new
  misc.ovl `kw_addrs` jmptable entry ($A012), and lookup() maps that bank around its matching. If
  misc.ovl is missing, keyword/function colouring silently stays off (strings/numbers/REM still
  colour). Earlier history: 278 B free at v0.9.238; the draw_text_row/draw_wrapped_row merge freed
  ~379 B but the wrap-scroll speed work spent it back.
  Original 36 B -> 278 B recovery (v0.9.238): folding the four ".ovl not found" literals into one
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
  - **More cold prose** — the big batch (21 toasts + prompts, ~290 B) is DONE via `msg_text`/`msg(id)`
    (see the Done entry). What's left is small: ~7 tiny toasts kept inline ("Saved", "Save error",
    "Not found", "Copied", "Loading...", "Saving...", "Replaced ", ~58 B total) - not worth a msg id
    each. The status-bar FOOTER strings (draw_status: "Line "/"Col "/"INS"/...) must stay inline: it
    repaints on every cursor move, so an overlay JSRFAR per keypress would defeat the wrap fast path.
    New cold prose goes to menus.ovl, NOT misc.ovl (misc is full).
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

## Done

- **Too-big file refused; session messages simplified (v0.9.287)** — (1) opening a file past the
  doc's line cap no longer shows a truncated half: act_open now resets to a fresh empty document
  (new_document) and says "File too big - not loaded" (was "...extra lines dropped"). (2) Dropped the
  "Session off - misc.ovl too old" message - misc.ovl is a REQUIRED overlay shipped with edit.prg, so
  an ABI-version mismatch can't happen in a real install (a missing/broken one halts at startup); if
  ses_ok were somehow false the session just stays off, no message. (3) Merged "Session unreadable"
  and "Session files missing" into one "Session issue, starting fresh." The msg table dropped 21 -> 19
  entries; free low RAM 535 -> 613 B. NOT emulator-tested.
- **21 cold status messages moved to menus.ovl (v0.9.285)** — session/save/backup/search/clipboard/
  undo toasts + the modal Y/N prompts (~450 B of literals) now live in the overlay's string pool
  behind `msg_text` (menus.ovl jmptable $A009, appended after mnu_bar). Main's `msg(id) -> uword`
  JSRFARs, copies the id-th message into `msgbuf[42]`, and returns its address, so notify /
  flash_notify / notify_blink / put_str_at call sites just read `notify(msg(MSG_X))`. The MSG_*
  consts in edit.p8 and the `when` in menus.p8 are the ABI (same order). Freed ~290 B (245 -> 535).
  Went to menus.ovl NOT misc.ovl: adding them to misc overflowed its 8 KB bank by ~220 B (misc is
  full - keyword tables + input-history ring). Tiny toasts (<=10 chars) and the hot draw_status
  FOOTER stay inline. Safe because menus.ovl is a REQUIRED overlay (start() halts if it is missing,
  before any msg() runs). NOT emulator-tested by the author - build only; verify each message still
  reads correctly (a wrong MSG_* id shows the wrong text).
- **Wrap SHIFT+arrow no longer full-repaints (v0.9.282)** — reported right after the how==0 fix:
  "word wrap on, SHIFT ARROW to highlight text redraws the whole screen". redraw_after_move's wrap
  branch still had `sel_active` in the full-repaint gate, so every selection-extend keypress redrew
  all ~58 rows. Dropped it: an active selection now rides the same two-row path, because
  draw_wrapped_row paints each row's own selection span and a single SHIFT+arrow only changes the
  highlight on the two edge rows (the row the cursor left, the one it landed on) - the rows already
  inside the selection don't change. No multi-row guard needed like the unwrapped path has, because a
  wrap how==1/2 is always exactly one visual row (ensure_visible_wrap's nxt-marker match). Only a far
  jump (how 3) or a just-cleared selection (force_full) still full-repaints. NOT emulator-tested.
- **Wrap in-window move no longer full-repaints (v0.9.280)** — the reported "word wrap on, very slow
  scroll, whole screen repainting". redraw_after_move's wrap branch lumped `how == 0` (cursor moved
  but stayed visible - no scroll) in with the full-repaint cases, so EVERY in-window cursor keypress
  redrew all ~58 rows (load + classify + VERA stream, ~10-15 ms) - and holding an arrow steps through
  a whole screen of those before it ever reaches a scroll edge. Now how==0 repaints exactly the two
  band rows like the unwrapped path: the OLD row is `cur_srow` (draw_wrapped_row records the cursor's
  screen row when it paints the band), and the NEW row is found by a segment-math walk down the window
  from (top_line, top_seg) - no rendering, ≤ TEXT_ROWS cheap iterations. A larger in-window jump (edge
  case) safely falls back to one full repaint. (An adjacency-only variant that skipped the walk was
  tried and was BIGGER in code, not smaller - the walk is the compact form.) NOT emulator-tested by
  the author - build only.
- **Top menu bar drawing moved into menus.ovl (v0.9.280)** — funded the how==0 fix. draw_menubar +
  draw_filename_title (~600 B: bar fill, six titles, active highlight, accelerator letters, filename +
  A/B/C indicator) were pure cold screen-painting, so they moved to menus.ovl's new `mnu_bar` entry
  ($A006, appended after mnu_item so its $A003 offset is unchanged). Main's draw_menubar is now a thin
  wrapper that packs the dynamic state into a 9-byte `menuctx` and JSRFARs. Theme COLOURS are packed
  in because the overlay is a separate program with its own theme copy (a custom palette would
  otherwise be ignored); menu_col/menu_len are static so the overlay hardcodes the columns while main
  keeps its copies for menu layout / hit-testing. Cold path (redraws only on full_redraw + menu
  open/close), and mnu_bar is only reachable after the required-overlay check, so a missing menus.ovl
  halts before it is ever called. NOT emulator-tested by the author - build only.
- **Overlays are REQUIRED; missing one -> tell + stop (v0.9.271)** — start() checks all four .ovl
  after loading; any missing -> `halt_no_ovl` names it, waits for a key, restores the screen, exits.
  Retired the graceful-degradation code (flash_no_ovl + its 5 UI guards, prompt_str's misc_ok guard),
  which funded the check. A present-but-stale overlay still degrades softly (missing != wrong version).
- **BASIC syntax keyword tables moved into misc.ovl (v0.9.268)** — ~450 B of low RAM reclaimed; see
  the RAM note at the top and [[edit-banked-overlays]]. syntax.lookup maps MISC_BANK around its reads.
- **Wrap-mode one-row-scroll VRAM fast path (v0.9.268)** — fixes the visible full-screen redraw
  (text + gutter) on every soft-wrap cursor move. A pure cursor move can't reflow the segments, so a
  one-row scroll is now a `vram_copy_row` window shift + exactly TWO row repaints: the row the cursor
  left (band off) and the row it landed on (band on). `ensure_visible_wrap` returns how it moved
  (0 visible / 1 down / 2 up / 3 far-jump) using the `(nxt_dl, nxt_seg)` marker - no load-walk - and
  maintains nxt on a down-step so sustained scrolling stays on the fast path (an up-step leaves nxt
  stale, which self-corrects to one full repaint on the up->down switch). Non-scroll moves and far
  jumps still full-repaint. REQUIRED it: the current-line band now marks only the cursor's VISUAL row
  in wrap mode (not the whole wrapped line), so the band moves by repainting two rows. Funded by the
  keyword-table banking (see the RAM note up top). NOT emulator-tested by the author - build only.
- **draw_text_row merged into draw_wrapped_row; wrap-scroll partially sped up (v0.9.256)** — the two
  renderers were ~85% duplicate; draw_text_row is now a one-line wrapper that calls draw_wrapped_row
  with the horizontal-scroll window as the "segment". Fixed two latent wrap-mode bugs in the process:
  the current-line band was hardcoded `$b0` instead of `theme.CB_BAND`, and `srcidx` was a `ubyte`
  that wrapped on lines past ~241 chars (the last segment redrew the START of the line). The shared
  renderer streams cells through VERA DATA0 with auto-increment (one address setup per row, not two
  per cell). Wrap scrolling was ALSO made lighter by removing ensure_visible_wrap's per-key
  load-walk (see the deferred fast-path candidate up top for what's still slow and why). NOTE: the
  merge saved ~379 B but the speed work spent it back down to 226 B free.
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
