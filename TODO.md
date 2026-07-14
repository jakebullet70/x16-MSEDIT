# EDIT - TODO

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
