# EDIT - TODO

- **Open-file popup: filter + delete** — in the Open file picker, add (1) a filter toggle that shows
  only BASLOAD source (the `has_basic_ext` set: `.bas` / `.basl` / `.bl` / `.bas.txt`), and (2) a Delete
  key that removes the highlighted file from disk (with a Y/N confirm) and drops it from the list. Both
  act on the existing `filelist` records in FLIST_BANK; delete uses `diskio.delete` + `void diskio.status()`
  (clear the channel), then re-reads the directory or compacts the list in place.
- **Test the installer** — `dist.bat` has never been exercised end to end since `help.ovl` joined the
  release. Run it, then in the emulator at the BASIC prompt: `CD"DIST"` + `^INSTALL` (answer `T` first
  for the dry run, then `Y`). Check: /MSEDIT is created with all four files, the /ED launcher works
  (`^/ED` from any folder), Help>Keyboard/About find the overlay, a REINSTALL keeps an existing
  edit.cfg, and running the installer from INSIDE /msedit skips the copy instead of truncating.
- **BASLOAD token picker popup** — a popup listing the BASLOAD control-code tokens (`{CLR}`, `{HOME}`,
  `{RVS ON}`, colour names, ...) so they can be picked and inserted at the cursor instead of typed from
  memory. The supported set is enumerated in the BASLOAD docs — mirror that list, don't invent one.
- **Escape-char popup** — same idea for the `/x`-style escape form (e.g. hex/`\x` character escapes):
  a pick-and-insert popup for the characters that are awkward to type.
- **Text file viewer (port from XFMGR)** — bring over XFMGR2's `tview` viewer (`../XFMGR2/SRC/tview.p8`),
  a scrollable read-only text/hex pager. It is already a banked-RAM `$A000` overlay blob, so it should
  drop in beside `help.ovl` as a second `extsub @bank` overlay (its own reserved bank) and cost EDIT
  almost no low RAM. Use it to view a file without loading it into the document (File > View...), which
  also side-steps the document size limits for a quick look at a big file.
