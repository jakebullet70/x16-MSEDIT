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
- **BUG: `ed.run` session file is written to the CURRENT dir, not the fsroot root** (filed 2026-07-22).
  `runstate = "ed.run"` (edit.p8:90) is a BARE relative name; ses_svc opens it with
  `diskio.f_open_w(runstate)` (edit.p8:3110, OP_OPEN_W) relative to the cwd. But the Open/View picker
  chdir's into whatever folder the user browses (picker.p8:261; edit.p8:2627 "the picker may have
  chdir'd", edit.p8:3293 "View can chdir too"), so a session save / BASLOAD / EDCFG hand-off that runs
  while the cwd is a subfolder writes `ed.run` THERE, not at the fsroot root. On reload the restore
  looks for it relative to the launch cwd (root), so a stray `ed.run` is orphaned in the subfolder and
  the session silently fails to restore. Contrast: the launcher is deliberately ABSOLUTE
  (`theme.ED_NAME = "/ed"`, theme.p8:157) and EDCFG explicitly `chdir("/")` before touching ed.run
  (edcfg.p8:170) — ed.run should follow the same "always at root" rule but doesn't.
  FIX OPTIONS: (a) `chdir("/")` around the ses_svc open/write/delete and restore the cwd after (mirrors
  EDCFG's cfg_write dance) — safest; (b) make `runstate` absolute "/ed.run" — BUT the host FS won't
  overwrite via an absolute path / @: (see [[edit-diskio-overwrite]]), so a bare-name-in-root write is
  still needed, i.e. (a) is the real fix. Repro: Open a file from a subfolder via the picker, then do an
  F5/EDCFG round-trip, and check where ed.run lands.
- **PRG2BASLOAD: auto-quote DATA items containing spaces** — BASLOAD lexes DATA content as identifiers,
  so `DATA HELLO WORLD` becomes `DATA HELLOWORLD` (see docs/basload-findings.md). The converter emits a
  `REM TODO` and leaves it. Better: split the DATA content on commas and wrap any unquoted item that
  holds a space in quotes. Careful with items that are already quoted, and with numeric items — quoting
  a number changes what `READ N` does.
- **BASLOAD token / `{}` picker popup** — a popup listing the BASLOAD control-code tokens (`{CLR}`,
  `{HOME}`, `{RVS ON}`, colour names, ...) so they can be picked and inserted at the cursor instead of
  typed from memory. MOTIVE: `{` and `}` cannot be typed AT ALL in the editor's locked lowercase PETSCII
  charset — no key emits byte 123/125 (the insert path at edit.p8:4918 would accept them fine if they
  arrived). The supported set is enumerated in the BASLOAD docs (basload.md) — mirror that list, don't
  invent one. Entry 0 is a bare `{}`: insert the pair, then `ed_left()` once so the cursor lands between
  the braces. Text-heavy, so build it as a banked overlay rather than in low RAM. Design settled
  2026-07-22:
  - Build it INTO picker.ovl (bank 8), not a new bank — it IS the picker widget. Append a `charpick`
    entry to picker's `%jmptable` (4th slot, after pick/picker_setup/del_sym; append-only so existing
    offsets don't shift, exactly how del_sym was added). Reuses draw_box_frame / draw_title_bar /
    draw_footer / wait_key / put_str_at + the Up/Down/PgUp/PgDn/Home/End nav — near-zero new low RAM.
  - The overlay RETURNS the chosen token text to a low-RAM `dest` buffer and returns 1 (exactly like
    `pick()` returns a filename); MAIN then loops `ed_insert()` over the bytes. The overlay never
    touches editbuf, so there is no cross-bank insert problem. Watch ed_insert's `cur_len >= MAX_LEN`
    guard: a multi-char token near the line-length limit inserts partially — main should check room first.
  - Insert the READABLE text token (`{DOWN}`), not the raw control byte ($11): matches the notation and
    stays greppable/editable. List entries can BE the token strings (label = payload).
  - List source: bake the canonical BASLOAD set into the overlay bank (robust, zero low RAM, no file
    dependency). Optional later: append a user `PETSCII.LST` if present, but keep the core baked in so a
    missing file can't break the feature.
  - Open from a menu item (Edit > "Insert Special..."): `{` can't be a hotkey and the Ctrl/F-key space
    is nearly full; a menu item costs no scarce keycodes and is discoverable.
  - CAVEAT — this fixes INPUT only, not DISPLAY. An inserted `{`/`}` SAVES correctly as ASCII (edoc
    p2a passes $7B/$7D through, edoc.p8:61) but RENDERS as a graphics glyph in the lowercase PETSCII
    charset — no brace glyph exists there, and draw_text_row draws every byte via petscii2scr
    (edit.p8:1179). The display half is the ISO/PETSCII investigation below.
- **Escape-char popup** — same idea for the `/x`-style escape form (e.g. hex/`\x` character escapes):
  a pick-and-insert popup for the characters that are awkward to type. Shares the picker.ovl `charpick`
  overlay + machinery with the token picker if both get built (different payload set, same widget).
- **Investigate supporting both ISO and PETSCII charsets** — the DISPLAY counterpart to the two picker
  popups above (filed 2026-07-22). In the editor's locked lowercase PETSCII charset, `{` `}` (and other ASCII
  punctuation missing from PETSCII — backslash, pipe, tilde, caret, grave, underscore) have no glyph
  and render as graphics chars via petscii2scr; ISO mode (charset 1) has the full ASCII set, so those
  would display correctly AND become directly typeable. The plumbing to
  track the mode already exists — snapshot/restore_machine_state carry the charset as 1=ISO / 2=upper-
  gfx / 3=lower (edit.p8:720) — and the on-disk format is ASCII either way, so files are unaffected AT
  THE FILE LEVEL for ASCII — but real ISO capitals DO corrupt on a load->save round-trip, see the
  HAZARD bullet below. A straight switch to ISO is a deep change, not a flag. Things to settle:
  - THE BLOCKER: the entire UI chrome is drawn with PETSCII box-draw glyphs (`sc:'┌'` etc. in every
    frame / menu / popup). One screen has ONE charset; under ISO those screen codes become Latin-1 and
    all the boxes turn to garbage. You cannot get box-draw glyphs AND ASCII braces from a stock ROM
    charset at the same time.
  - Likely real answer: a CUSTOM uploaded 8x8 VRAM charset that keeps the box-draw glyphs where the UI
    expects them AND puts `{` `}` (etc.) at 123/125. This ties directly to the "Thin font like
    inspector.prg" item below (also a custom-charset upload) — investigate them together.
  - Internal storage is PETSCII today: edoc.a2p/p2a case-fold on load/save (edoc.p8:54) and the
    software-caps `upper_mode` fold ($41-$5A -> +$80) assume PETSCII upper. Running the text area in ISO
    would make internal bytes ASCII and those conversions/folds wrong — they'd have to become no-ops or
    branch on the active mode. This, not the display, is the subtle cost.
  - HAZARD (verified 2026-07-22): the a2p/p2a fold isn't merely "wrong under ISO" — it actively CORRUPTS
    existing ISO-8859-15 files on a load->save round-trip, TODAY. p2a treats $C1-$DA as PETSCII uppercase
    and subtracts $80 (edoc.p8:64), but $C1-$DA is exactly the ISO-8859-15 range for accented capitals
    Á…Ú. Root cause: on load a2p leaves a $C1 byte unchanged (edoc.p8:59), so ISO-`Á` and PETSCII/ASCII-`A`
    both become internal $C1 — indistinguishable — and on save p2a maps both back to `A` ($41). Net: open
    an ISO file containing `Á`/`É`/`Ñ` etc., save it, and the accents are silently stripped to plain ASCII
    `A`/`E`/`N`. Other high bytes (é=$E9, €=$A4, ñ=$F1) round-trip byte-for-byte but display as PETSCII
    graphics glyphs; ONLY $C1-$DA loses data. Latent for now (no key emits $C1-$DA in the locked lowercase
    charset) — the trigger is opening pre-existing ISO text, not typing it. Whatever the ISO fix becomes,
    a2p/p2a must stop case-folding blindly (branch on active mode, or drop the fold and store what's on
    disk). REFERENCE ARCHITECTURE — the ROM's own X16 Edit (Stefan Jakobsson, `edit` at the BASIC prompt;
    src X16Community/x16-rom/x16-edit, verified 2026-07-22) never hits this because it is an ENCODING-
    AGNOSTIC RAW-BYTE editor: (1) load/save move bytes VERBATIM — only transforms are CR/CRLF<->LF newline
    normalization + TAB->spaces on load (file.inc file_read/file_write); no ASCII<->PETSCII fold, so every
    $80-$FF byte round-trips intact. (2) The buffer holds the file's raw bytes; PETSCII->screencode
    conversion happens ONLY at draw time and ONLY in PETSCII display modes — in ISO mode the byte goes
    straight to VERA (screen.inc, gated on `screen_mode`). (3) CTRL-E cycles charsets as a PURE DISPLAY
    repaint (cmd.inc cmd_encoding_set -> KERNAL $ff62 + screen_mode flag + screen_refresh); the buffer is
    never touched, and it calls the ISO font freely. It gets away with runtime charset cycling because its
    chrome is NANO-STYLE — colored blank-space bars + ASCII letters, ZERO box-draw glyphs (screen.inc
    screen_print_header/footer) — so flipping to ISO breaks nothing. TWO lessons for EDIT: (a) the
    corruption fix is to move charset conversion OFF the storage boundary (a2p/p2a) onto the DISPLAY
    boundary only, where petscii2scr already is — display conversion is lossless because it's never
    written back; (b) our PETSCII box-draw chrome is the SOLE reason we can't just flip to ISO the way X16
    Edit does — which is exactly what option (a)'s custom font buys back (box-draw + ASCII glyphs in one
    uploaded charset, so no mode flip needed). X16 Edit chose the other trade: plain chrome, free cycling.
  - Decide scope: (a) custom charset that just makes braces real (preferred — unifies the popups + the
    thin font), (b) a runtime ISO/PETSCII toggle for the text area only (needs chrome rework +
    conditional a2p/p2a/caps), or (c) do nothing, ship the token popup, live with the brace glyph.
  - Reminder why we're on lowercase PETSCII and not ISO already: the Caps-Lock handling
    (disable_caseswitch + the software toggle, [[edit-caps-lock-fix]]) was built around PETSCII; ISO
    was weighed during that work and set aside.
- **Ctrl+Shift+PgUp/PgDn to select to the file ends** — small follow-on to the Ctrl+PgUp/PgDn jump
  added in v0.9.211. `ed_doc_jump` does not touch the selection today, matching plain PgUp/PgDn.
  Shift+Home / Shift+End (keycodes 147 / 132) already extend on the line, so the pattern exists; the
  open question is whether the X16 keymap delivers a distinguishable Ctrl+Shift+PgUp at all.
- **F12 on `#INCLUDE` jumps to the included file** — when the cursor is on an `#INCLUDE` line, F12
  follows it: if the referenced file is already open in one of the A/B/C slots, switch to that slot;
  otherwise open it (or drop into File > View if no slot is free / it isn't a source we want to edit).
  Parse the filename off the `#INCLUDE` directive on the current line, resolve it relative to the
  current document's directory, then reuse act_window_goto / the picker's open path.
- **Batch BASLOAD build tool (LOADBATCH.PRG)** — a small utility that build-runs a whole project of
  BASLOAD sources from one plain-text script. The script is one `BASLOAD"NAME.BAS"` per line, e.g.:

  ```text
  BASLOAD"BBSINIT.BAS"
  BASLOAD"LOGIN.BAS"
  BASLOAD"SYSOP.BAS"
  BASLOAD"PWMAINT.BAS"
  BASLOAD"BBSMSG.BAS"
  ```

  Because each source has `#SAVEAS`, every BASLOAD writes its own PRG — the script needs no SAVE lines.
  The mechanism: BLOAD the script text to $A000, zero-terminate it at the load end (the
  `PEEK($30D)+PEEK($30E)*256` end-of-load pointer), then `EXEC $A000,10` to march through every line. A
  minimal hardcoded 3-line loader works (BLOAD the fixed script name, POKE the terminator, EXEC). Ship
  it instead as a prompt-driven **LOADBATCH.PRG** that asks for the script name:

  ```basic
  10 XR = $030D
  20 YR = $030E
  30 CLS:PRINT
  40 PRINT " ENTER BATCH FILE NAME -->";
  50 LINPUT F$
  60 BLOAD F$,8,10,$A000
  70 POKE PEEK(XR)+(256*PEEK(YR)),0
  80 EXEC $A000,10
  ```

  Decide: build it as a shipped .PRG (like prg2basload.prg) and/or expose it from EDIT's Dev menu; and
  whether EDIT can generate the BUILDALL.TXT script from the open documents / a project's .BAS files.
- **User-saved per-folder session file (Dev menu)** — a Dev-menu action that writes a session-like file
  recording the currently open documents, one such file PER FOLDER (a project's own session). On EDIT
  startup, look for it and, if found, auto-load its files. Lookup precedence: a session file in the
  ROOT wins; otherwise use one found in the CURRENT directory. This is DISTINCT from the automatic
  `ed.run` 3-doc restore ([[edit-session-restore]]) — that one is implicit/global and about resuming
  the last edit; this is an explicit, user-created, project-scoped "open this set of files" list.
  Decide: its own filename/format vs. reusing the ed.run layout; how it interacts with (or overrides)
  ed.run restore at startup; and whether "root" means the fsroot we launched in (`STARTDIR_ADDR`) or a
  drive root.

## Done

- **Thin display font (build 380)** — inspector.prg turned out to just use a STOCK KERNAL charset
  (`POKE $030C,4:SYS $FF62`), no custom upload. So EDIT simply loads the thin PETSCII upper/lower
  charset (5) instead of 3 in apply_charset_mode, and captures the `{ } \ | ~` patch glyphs from the
  thin ISO font (charset 6) so they match. Box-draw chrome + lowercase + ISO glyphs verified thin. No
  RAM cost. It's just a charset number, so trivial to revert.

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
