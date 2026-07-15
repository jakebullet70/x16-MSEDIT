# EDIT - TODO

- **Open-file popup: filter + delete** — in the Open file picker, add (1) a filter toggle that shows
  only BASLOAD source (the `has_basic_ext` set: `.bas` / `.basl` / `.bl` / `.bas.txt`), and (2) a Delete
  key that removes the highlighted file from disk (with a Y/N confirm) and drops it from the list. Both
  act on the existing `filelist` records in FLIST_BANK; delete uses `diskio.delete` + `void diskio.status()`
  (clear the channel), then re-reads the directory or compacts the list in place.
- **Test the installer** — `dist.bat` has never been exercised end to end since the overlays joined the
  release. Run it, then in the emulator at the BASIC prompt: `CD"DIST"` + `^INSTALL` (answer `T` first
  for the dry run, then `Y`). Check: /MSEDIT is created with all six files (edit.prg, edcfg.prg,
  misc.ovl, tview.ovl, edit.hlp, edit.cfg), the /ED launcher works (`^/ED` from any folder),
  Help>Keyboard opens edit.hlp in the viewer, Help>About and File>View work, a REINSTALL keeps an
  existing edit.cfg, and running the installer from INSIDE /msedit skips the copy instead of truncating.
- **BASLOAD token picker popup** — a popup listing the BASLOAD control-code tokens (`{CLR}`, `{HOME}`,
  `{RVS ON}`, colour names, ...) so they can be picked and inserted at the cursor instead of typed from
  memory. The supported set is enumerated in the BASLOAD docs — mirror that list, don't invent one.
- **Escape-char popup** — same idea for the `/x`-style escape form (e.g. hex/`\x` character escapes):
  a pick-and-insert popup for the characters that are awkward to type.
- **Markdown (.md) syntax colouring** — a second file-type mode alongside the BASIC classifier in
  `SRC/syntax.p8`, selected when the loaded file has a `.md` extension. Keep it minimal: just TWO
  colours. Colour heading lines (a line starting with `#` or `##`) as one accent colour and leave
  the rest as body text — reuse existing theme slots (e.g. `C_KEYWORD` for headings) rather than
  adding new theme bytes. Also handle `/#` as an ESCAPE: a leading `/#` means "the `#` that follows
  is a literal `#`, not a heading" — so that line renders as plain body text (and ideally the `/`
  is dropped so only the real `#` shows). Line-oriented and stateless like the BASIC path.
