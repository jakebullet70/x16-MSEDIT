# ISO-MODE plan

Goal: let EDIT run in the X16 KERNAL ISO-8859-15 charset (charset 1) so that
`{` `}` `\` `|` `~` backtick and the Latin-9 accented characters display
correctly and are typeable, and so text files round-trip without the PETSCII
case-fold corrupting them. Reference implementation: the ROM's own X16 Edit
(see "Reference architecture" below and the HAZARD note in TODO.md).

Branch: ISO-MODE. Status: planning only, no code yet.

## The flag

Introduce `const bool ISO_MODE = false`.

- `false` = today's PETSCII-lowercase behavior, byte-for-byte. Because prog8
  `const` is compile-time, the compiler dead-strips every `if ISO_MODE {...}`
  true-branch, so the false build is identical to today's binary at zero RAM /
  code cost. This is the "set to false and it all still works" guarantee.
- Flip to `true` (rebuild) to get the ISO behavior once each branch below is in.
- Promote `const` -> runtime `bool` (menu toggle) ONLY after the feature is
  proven. A runtime var keeps both branches in the binary and therefore costs
  low RAM (chronically scarce), so that is a deliberate later step, not now.

## The reframing (important)

Flipping the real KERNAL charset to ISO does NOT just garble the box-draw
chrome -- it garbles EVERY piece of the editor's own on-screen text. Every
label ("File", "Line", "Open or save a file first") is a PETSCII string literal
(prog8 default encoding; there is no `%encoding` directive) drawn through
`txt.petscii2scr` against what would now be the ISO font. Walking bytes:

- lowercase a-z  -> blank / garbage  (e.g. "File" renders as 'F' + 3 blanks)
- uppercase, digits, space, punctuation -> survive by coincidence
- box-draw glyphs -> garbage (independently)

So there are two very different things ISO_MODE=true can mean:

| aspect | Path A: flip real KERNAL charset | Path B: custom uploaded font |
|---|---|---|
| KERNAL charset | switched to ISO | stays PETSCII-lower (never flips) |
| UI strings + chrome | all need rework | untouched (PETSCII glyphs at PETSCII slots) |
| ISO letters / accents | free from ROM ISO font | author every glyph + fix }/backtick/^ slot collisions |
| size | large | small, but needs font art + remap |

The checklist below is for **Path A** (the "IF ISO ... ELSE ..." branch
approach). Both code audits recommend Path B as cheaper for the CHROME half; the
recommendation at the end splits the work accordingly.

## Path A checklist -- every ISO_MODE branch point

### 1. Charset & mode (1 site)
- [x] DONE `edit.p8:543`: full ISO switch (NOT just the font) - `cx16.screen_set_charset(1,0)` +
      `$0372 |= $40` (KERNAL_MODE ISO flag) + EXTAPI `jsr $feab` (A=$05 X=$9f, C=0). Font alone left the
      keyboard in PETSCII (no `{}`); the mode-flag + EXTAPI make keys emit ASCII. Matches ROM X16 Edit
      (cmd.inc iso:). Keep `sys.disable_caseswitch()` in BOTH modes.
- No change: snapshot/restore `edit.p8:716-735` already handles charset 1..3 (ISO=1).

### 2. Document rendering (1 site -- the easy half)
- [ ] `edit.p8:1179` `ch = txt.petscii2scr(@(sp))` -> write the byte directly
      (screencode = ISO byte) when ISO_MODE. Single funnel: `draw_text_row`
      (`edit.p8:1079`) and `draw_all_text_wrapped` (`edit.p8:1227`) both route
      through `draw_wrapped_row` (`edit.p8:1099`). Mirrors X16 Edit's
      screen_mode==0 skip.

### 3. Storage -- also the corruption fix (1 pair)
- [ ] `edoc.p8:54-67` `a2p` / `p2a` -> identity pass-through when ISO_MODE.
      Call sites: load `edoc.p8:255`, save `edoc.p8:279`. This is simultaneously
      the fix for the $C1-$DA ISO-capital save-corruption.
- Note: `edoc.p8:249` scrubs bytes <32 on load; in ISO consider whether $7F-$9F
  (ISO control range) should also be scrubbed. Minor.

### 4. Input -- caps + key/accelerator folds (~10 sites)
All currently assume the keyboard emits PETSCII (shifted letters $C1-$DA); in
ISO it emits ASCII (unshifted $61-$7A). Each fold flips from `$C1-$DA -$80` to
`$61-$7A -$20`. Target range stays $41-$5A in both modes.
- [ ] Software-caps fold `edit.p8:4919` (`$41-$5A +$80` -> `$61-$7A -$20`; note
      direction flips: fold DOWN not up)
- [ ] `confirm_save` `edit.p8:1942`
- [ ] `confirm_overwrite` `edit.p8:1960`
- [ ] `item_accel` (dropdown accelerators) `edit.p8:2175`
- [ ] `prompt_replace` y/n/a `edit.p8:3574`
- [ ] picker hotkeys `picker.p8:182`, filter `picker.p8:537`
- [ ] viewer search `tview.p8:415`, viewer nav `tview.p8:601`
- [ ] overlay prompt gate `misc.p8:339` (also widen to `k >= $a0` if accented
      input should be accepted)
- No change: insert gate `edit.p8:4918` itself (coincidentally OK; the >=160
  clause now admits ISO accented $A0-$FF instead of PETSCII graphics).
- No change: `ed_insert` `edit.p8:4653` (stores k verbatim).

### 5. Classifiers -- 2 folds cascade to ~6 consumers
- [ ] Syntax `syntax.p8:45-52` fold + `syntax.p8:54-56` is_letter -> ISO ranges
      (is_letter add $61-$7A; fold: fold $61-$7A down, drop the $C1-$DA branch).
      Covers eq/in_blob/lookup, which all route through fold.
- [ ] Search `edit.p8:3329-3334` fold -> add `$61-$7A -$20`. ONE fix auto-corrects
      `line_match` (`edit.p8:3407`), `ends_with_ci` (`edit.p8:3360`),
      `is_word_char` (`edit.p8:3351`), `rem_start` (`edit.p8:3890`).

### 6. Inserted-text bytes (1 site)
- [ ] `cmt_prefix = [$d2,$c5,$cd,$20]` "REM " in PETSCII `edit.p8:3878`
      -> ASCII `[$52,$45,$4d,$20]` when ISO_MODE. (rem_start detection already
      compares folded $52/$45/$4d, so it stays correct once fold is ISO-aware.)

### 7. UI chrome glyphs -- 8 drawers across 3 compilation units
Emit ASCII `+` `-` `|` (and `^` / `v` for the arrows) instead of box glyphs when
ISO_MODE. Constant blocks: `edit.p8:56-65`, `picker.p8:47-53`, `misc.p8:60-67`.
Cheapest form: a per-unit runtime glyph table (3 init sites) rather than
branching ~47 individual setchr statements.
- [ ] `edit.p8`: `attn_frame` :825, `draw_box_frame` :904, `draw_menu_sep` :946,
      `draw_box_sep` :956  (edit.p8 owns the tees SC_VR $6b / SC_VL $73)
- [ ] `picker.p8`: `draw_box_frame` :590
- [ ] `misc.p8`: `prompt_box` :219, `draw_box_frame` :693, `draw_hist_hint` :680
      (misc.p8 owns SC_UP $1e up-arrow)
- No change: menus.ovl and tview.ovl draw ZERO glyphs (spaces + text only).
- No change: drop-shadow is a color (`theme.p8:41` CB_SHADOW $cc), not a glyph.

Constants (all units): SC_TL $70, SC_TR $6e, SC_BL $6d, SC_BR $7d, SC_H $40,
SC_V $5d, SC_VR $6b, SC_VL $73, SC_UP $1e.

### 8. UI strings -- the invasive core of Path A
Every label / prompt / message is a PETSCII literal drawn via `put_str_at`
(`edit.p8:780`; duplicated `menus.p8:146`) -> petscii2scr -> setchr, and all go
garbage under the ISO font. Consumers: `draw_status` `edit.p8:1758`, `box_msg`
`edit.p8:851`, `mnu_bar` `menus.p8:155`, `mnu_item` `menus.p8:56`, `mnu_mode`
`menus.p8:40`, About `misc.p8:180`, `ovl_prompt` `misc.p8:247`, picker rows
`picker.p8:570`.
- [ ] Decide a strategy: (a) re-author every UI literal in ASCII + convert
      per-mode at draw time, or (b) make the draw primitive apply a PETSCII->ISO
      conversion when ISO_MODE. This is the bulk of Path A's work and is exactly
      what Path B (custom font) avoids entirely.

### 9. Help viewer (2 sites, second code path)
- [ ] `tview.p8:126` `scr_of` -> identity branch under ISO. The tview footer uses
      `txt.print` / `chrout` (`tview.p8:106,508`), which renders wrong-case under
      ISO.
- No change: `tview.p8:330` `view_fold` is already correct ASCII folding.

### 10. Decisions -- settle BEFORE building
- [x] RESOLVED (emu test): the X16 keyboard DOES emit `{` `}` etc. in ISO mode -
      but ONLY after item 1's FULL switch (font + $0372 bit $40 + EXTAPI). Font-only
      gave no braces. So ISO_MODE CAN be the input path; the insert popup is likely
      UNNEEDED once chrome (items 7-9) is solved.
- [ ] Filenames stay PETSCII by rule (`theme.p8:14` -- host FS matches those
      bytes). `fold_str` / `ends_with_ci` / `picker.fold` (`edit.p8:3336-3378`,
      Save As call sites `edit.p8:2635/2649`) are a SEPARATE encoding axis: keep
      folding to $41-$5A but branch the source range. Do not treat as document
      text.
- [ ] Control-byte range scrub on load (item 3 note).
- [ ] EDCFG sibling (`edcfg.p8:32-37` constants + its "Saving" box ~283-303) only
      if ISO_MODE should also cover the standalone config tool. `install.p8` needs
      nothing. BASIC-chain control codes (`edit.p8:2895-3004`) are unaffected.

## What does NOT change
Colors, selection highlight, current-line band, drop-shadow, cursor, gutter
digits, is_digit, ed_insert, snapshot/restore charset, and both menus.ovl /
tview.ovl chrome. Digits, space, and punctuation render identically in both
charsets. `capture_err_row` (`edit.p8:3138`) stores screencodes 65-90 that land
on A-Z in both fonts -- coincidentally OK.

## Sizing
- Items 1-6 (charset, render, storage, input folds, classifiers, cmt_prefix):
  small and clean -- ~15 well-defined single-line branches, mostly "flip the
  fold range." This half ALSO fixes the ISO round-trip corruption and makes the
  internals encoding-clean, independent of the chrome question.
- Items 7-9 (chrome + all UI strings + viewer): the large, invasive part -- pure
  UI plumbing that Path B (custom font) avoids entirely.

## Recommendation
1. Land items 1-6 as their own increment. They are independently valuable: they
   fix the $C1-$DA corruption and make the byte model encoding-agnostic (the X16
   Edit model: convert at the DISPLAY edge only, never at storage).
2. For the chrome / UI-string half, prefer Path B (a custom uploaded 8x8 charset
   carrying box-draw AND the ASCII/brace glyphs) over items 7-9, so the UI never
   has to become charset-aware. This unifies with the "thin font like
   inspector.prg" TODO item. Caveat already on record: a custom font hits fixed
   petscii2scr slot collisions -- document `}` -> screen $5d = box rail; backtick
   -> $40 = box edge; `^` -> $1e = up-arrow -- so it needs a small draw-time
   remap for those ~3 characters (`{` at $5b is free).

## Reference architecture -- the ROM's X16 Edit
X16 Edit (Stefan Jakobsson; `edit` at the BASIC prompt; src
X16Community/x16-rom/x16-edit) does not hit any of this because it is an
ENCODING-AGNOSTIC RAW-BYTE editor:
- load/save move bytes verbatim (only CR/CRLF<->LF newline normalization + TAB
  -> spaces on load); no ASCII<->PETSCII fold, so every $80-$FF byte round-trips.
- the buffer holds raw bytes; PETSCII->screencode conversion happens only at draw
  time and only in PETSCII display modes (ISO writes the byte straight to VERA).
- CTRL-E cycles charsets as a pure display repaint (KERNAL $ff62 + a screen_mode
  flag + refresh); the buffer is never touched.
- it cycles charsets freely because its chrome is nano-style: colored blank-space
  bars + ASCII letters, ZERO box-draw glyphs -- nothing for ISO to break.

The two lessons EDIT takes from it: (1) move charset conversion off the storage
boundary onto the display boundary (where it is lossless); (2) our PETSCII
box-draw chrome is the SOLE reason we cannot flip to ISO the way X16 Edit does --
which is what Path B's custom font buys back.

## Per-document ISO/PETSCII - scope (decided 2026-07-22)

GOAL: each of the 3 doc slots (A/B/C) remembers PETSCII or ISO; switching docs reconfigures
display + keyboard. Only ONE doc shows at a time (VERA = one font per screen), so per-doc =
swap font + mode on doc-switch, not two fonts on screen at once.

DECISIONS:
- Custom font lives at its OWN VRAM tilebase (`VERA_L1_TILEBASE`), loaded ONCE at startup;
  mode-flip = point the tilebase register, NO 2KB re-upload. `screen_set_charset` only touches
  the default charset slot, so the custom font is never clobbered. (New VERA register for EDIT.)
- Font ships as `FONT.BIN` beside edit.prg, BLOAD'd into VRAM at boot (0 low RAM, +1 file, like
  the .ovl/.md). Reuse the `diskio.loadlib` pattern (`edit.p8:597`).
- Mode pick: New (untitled) = PETSCII; Open inherits the current active mode; boot = last
  session's active mode (persisted in the CTX blob / ed.run). NO extension auto-detect.
- Glyph set: `{} \ | ~` only (no Latin-9 accents) - fits with room to spare.

PLUMBING (cheap):
- Per-doc `bool iso_mode`: +1 CTX field after `hl_mode` (`edit.p8:340/350`), `NCTXF` 42->43.
  Rides the banked CTX blob -> +1 B low RAM (the live global). `CTX_SIZE` unchanged (237 B slack).
- `SES_VER` 4->5 REQUIRED (CTX layout shifts). ed.run file size +0 (padding). `SES_PTRS` /
  `SESOVL_VER` unchanged.
- Extract start()'s ISO block (`edit.p8:543-564`) -> `apply_charset_mode(bool iso)`. Call from
  `switch_doc` (`edit.p8:2515`), `ses_svc` OP_ACTIVATE (`edit.p8:3099`), and startup for slot A.
  `blank_slot` (`edit.p8:2472`) sets the default.

THREE NEW SUBSYSTEMS (the real work):
1. Reverse charset path (ISO->PETSCII): start()'s switch is ONE-WAY. `apply_charset_mode`'s
   PETSCII branch must clear `$0372 &= ~$40`, re-call EXTAPI (`$feab`, A=$05 X=$9f) for PETSCII,
   and reset `cmt_prefix` to PETSCII `[$d2,$c5,$cd]`. ~30 B, all new.
2. Custom font upload (own tilebase): NEW - no tilebase / charset-VRAM code exists today. BLOAD
   `FONT.BIN` to a dedicated VRAM address at boot; flip `VERA_L1_TILEBASE` per doc. Design the
   256-glyph font: PETSCII/box-draw layout + `{} \ | ~` + the 3-slot remap (doc `}`->$5d=box rail,
   backtick->$40=box edge, `^`->$1e=up-arrow; `{` at $5b free). ~60-120 B code + 2KB VRAM data.
3. Clipboard mode tag: clip = raw bytes, no tag; cross-mode paste CORRUPTS ($41-$5A overlap:
   PETSCII-lower = ISO-upper -> case flip on screen AND on save). Add +1 B `clip_iso` (precedent
   `clip_line`, `edit.p8:180`) + convert-on-paste via `a2p`/`p2a` when src mode != dest. ~50-70 B.

RAM: full feature ~340-480 B new vs 388 free -> reclaim needed before the font + clip land.
Candidates (each > the shortfall): `item_accel`->menus.ovl ~200 B, REM builders ~200 B,
`chain_load` ~180 B, search matcher ~150 B, `berr`->CLIP ~70 B (see [[edit-lowram-reclaim]]).

PHASES:
1. `apply_charset_mode(iso)` + reverse (ISO->PETSCII) path + per-doc `iso_mode` CTX field
   (const->runtime) + `SES_VER` 4->5. Cost ~112 B -> FITS in 388 (no reclaim needed yet). Test:
   doc A PETSCII / doc B ISO switch. No font yet -> ISO doc chrome garbage (acceptable interim).
2. RECLAIM ~200-400 B (`item_accel` + REM builders -> menus.ovl) - before the font + clip code.
3. Custom font: `FONT.BIN` own-tilebase upload + tilebase flip + the 3-glyph remap. Fixes ISO chrome.
4. Clipboard mode tag + convert-on-paste.
5. Footer per-doc PETSCII/ISO indicator.
