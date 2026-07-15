# EDIT — a text editor for the Commander X16

A small, full-screen text editor for the **Commander X16**, styled after the classic
**MS-DOS EDIT**: a menu bar up top, dropdown menus, a status line at the bottom, and
the whole document held in **banked RAM**.

Written in [prog8](https://prog8.readthedocs.io/). Runs on real X16 hardware and in the
`x16emu` emulator, in both 80-column and 40-column text modes.

> **Version 0.9.103** · © sadLogic 2026 · Open source

---

## Why this project exists

EDIT was written **almost entirely by an AI coding agent** (Claude / Claude Code),
directed and reviewed by a human. It is less a "product" and more a hands-on experiment in
**learning how to control an AI** — how to prompt it, correct it, and review its work while
it builds real, low-level software from scratch.

The Commander X16 was chosen *because* it is niche and unforgiving. There is very little
training data for its banked-memory model, VERA video chip, and PETSCII quirks, so the AI
can't coast on memorised answers — every feature is a genuine back-and-forth between the
operator and the model. If you're curious what it looks like to steer an LLM through a real
6502-era codebase, this repo is the artifact of that process.

## Highlights

- **Document lives in banked RAM.** The text isn't capped by the ~38 KB of low RAM — lines
  are stored in the X16's banked HIRAM (`$A000+`) through a small storage layer (`edoc` +
  `xarena`), so documents grow into the extra RAM banks the machine has installed.
- **MS-DOS EDIT look & feel** — menu bar, dropdown menus (File / Edit / Search / Help),
  drop-shadowed popups, and a live status bar (line, column, INS/OVR, total lines).
- **Adopts your screen mode** — boots into 80×30 or 40×30 to match however the machine
  started, and lays the UI out to fit.
- **Full editing** — insert/overwrite, word-wrap-free line editing, selection with
  Shift+arrows, cut / copy / paste, find, find-next, replace-all, and go-to-line.
- **Undo / redo** — a per-line history kept in banked RAM, so multiple steps of undo cost
  no low-RAM headroom (see [Undo / redo](#undo--redo) below).
- **BASIC syntax coloring** — an optional highlighter for X16 BASIC (keywords, strings,
  numbers, line numbers, and green `REM` comments), toggled from the Edit menu. It's
  display-only and stateless per line, so it never touches what's saved and keeps scrolling
  fast.
- **Line numbers** — an optional left-hand gutter that numbers each line, toggled from the Edit
  menu. Display-only, and the number for the line you're on is highlighted.
- **Soft word wrap** — an optional display-only wrap (Edit menu) that folds long lines at word
  boundaries across screen rows without ever changing the file; arrow keys move by the wrapped
  rows you see.
- **Run through BASLOAD** — press **F5** to save the current file, hand it to the ROM
  [BASLOAD](https://github.com/stefan-b-jakobsson/basload-rom) tool (which tokenizes plain-text
  BASIC source into a runnable program) and run it. EDIT arms **F8** so one keypress brings
  you back to the editor at the same file and line (see [Run through BASLOAD](#run-through-basload)).
- **Plain ASCII on disk** — text is edited in PETSCII internally but saved and loaded as
  plain ASCII, so files interchange cleanly with other tools.
- **Restores your environment on exit** — screen mode, charset, text colour, and the case
  switch are captured at launch and put back when you quit.

## Keyboard reference

Open the menus with **Esc** or **Alt** (the Commodore key). Menu accelerators are the
highlighted red letter (e.g. `Alt`+`F` → File).

### Movement

| Key | Action |
| --- | --- |
| Arrow keys | Move cursor |
| Ctrl + Left / Right | Jump a word |
| Home / End | Start / end of line |
| PgUp / PgDn | Page up / down |

### Editing

| Key | Action |
| --- | --- |
| Shift + arrows | Select text |
| Tab | Insert 4 spaces |
| Insert | Toggle insert / overwrite (INS / OVR) |
| Backspace | Delete character to the left |
| Enter | Split line / new line |
| Ctrl+C | Copy |
| Ctrl+X | Cut line |
| Ctrl+V / F4 | Paste |
| Ctrl+K | Delete line |
| Ctrl+↑ / Ctrl+↓ | Move line up / down |
| Ctrl+Z | Undo |
| Ctrl+U | Redo |

**Enter auto-indents** — a new line starts with the same leading spaces as the line you left.
**Duplicate Line** and **Move Line Up/Down** are on the **Edit** menu (Move also has the Ctrl+↑/↓
keys above). The line the cursor is on is shown with a subtle highlight band.

### Search

| Key | Action |
| --- | --- |
| Ctrl+F / F6 | Find |
| Ctrl+G / F3 | Find next |
| Ctrl+R / F8 | Replace (interactive) |
| Ctrl+J | Go to line |

Search is case-insensitive. **Find** and **Find next** **wrap around** — when they reach the end
of the document they continue from the top and show *"Wrapped to top."* **Replace** is
**interactive**: after you enter the search and replacement text, EDIT highlights each match and
asks **`Y`** (replace), **`N`** (skip), **`A`** (replace this and all the rest), or **Esc** (stop).
The whole replace run is a single undo step.

**Whole Word** — toggle it with **Cmdr+W** (the Commodore key + `W`) while the Find or Replace
prompt is open; the search bar shows **Whole Word On/Off** on the right, and the trigger letter is
highlighted just like a menu accelerator. When on, both Find and Replace match only when the term
stands as its own word — bounded by non-alphanumeric characters — so searching `cat` skips the
`cat` inside `cats` or `category`.

### Files & help

| Key | Action |
| --- | --- |
| Ctrl+N | New |
| Ctrl+O | Open (file picker) |
| F2 | Save |
| F5 | Run through BASLOAD |
| F1 | About |

**Save As** asks before overwriting an existing file. Prompts that appear on the status bar
(Save-changes, Find, Replace, Go-to) flash once so they're easy to notice.

**File → View...** opens any picked file read-only in a scrollable text/hex viewer (a banked
overlay, `tview.ovl`) without loading it into the document — handy for peeking at a file that's
too big to edit. Inside the viewer: PgUp/PgDn page, `T`/`B` top/bottom, `H` toggles hex, `F` finds,
`N`/Space find-next, `Q`/Esc quits. **Help → Keyboard** shows the `edit.hlp` help file in the same
viewer.

> **Note for emulator users:** `x16emu` intercepts a few Ctrl chords before they reach the
> program — `Ctrl+F` (fullscreen), `Ctrl+V` (host paste) and `Ctrl+R` (reset). EDIT provides
> function-key aliases (**F6** = Find, **F8** = Replace, **F4** = Paste) that work on both the
> emulator and real hardware.

## Undo / redo

EDIT keeps an undo history so you can walk edits back and forward. Press **Ctrl+Z** to undo
and **Ctrl+U** to redo; both are also on the **Edit** menu (Undo / Redo).

A few things worth knowing about how it works:

- **Per-line granularity.** History is tracked a line (or a structural change) at a time, not
  a keystroke at a time. One Ctrl+Z reverts everything you typed on a line as a single step,
  and it also unwinds structural edits — an Enter-split rejoins, a Backspace/Delete line-join
  splits back apart, a deleted or pasted line comes back or goes away, a multi-line selection
  delete is restored in one step, and a **Replace-all** or a **multi-line paste** is undone in
  one step too.
- **Undo survives a Save.** Saving no longer discards the history — you can save and still walk
  your edits back afterward.
- **Stored in banked RAM.** Snapshots live in the same banked-RAM arena as the document (up to
  32 steps deep), so a deep history costs no scarce low RAM. A Replace-all or paste that changes
  more than 32 lines at once is the one case that can't be fully tracked, so it clears history.
- **A fresh edit clears the redo stack** — the usual editor behaviour.
- **History is cleared only when the whole document is replaced** — starting a **New** document
  or **Opening** a file. After that, Ctrl+Z reports *"Nothing to undo."*

## Syntax coloring

For BASLOAD source, (.BASL, .BL, .BAS.TXT ) EDIT can highlight X16 BASIC **keywords**, **strings**, **numbers**, leading
**line numbers**, and comments (shown in green) — both `REM` and BASLOAD's `##` to end of line.
Toggle it from the **Edit** menu
(*Syntax Color*). Coloring is purely a display layer — it never changes the bytes on disk — and
because BASIC lines are self-contained, only the rows actually on screen are re-colored, so it
stays out of the way while you scroll.

**Auto-detection on open:** coloring is **off by default**, and is switched on automatically when
you open a BASIC-source file — any name ending in **`.bas`**, **`.basl`**, **`.bl`**, or
**`.bas.txt`** (case-insensitive). Opening anything else switches it back off. You can always
override with the Edit-menu toggle.

## Line numbers

An optional left-hand **gutter** that shows each line's number. Toggle it from the **Edit** menu
(*Line Numbers*, default off). The numbers are display-only — they never touch the saved bytes —
and the gutter widens automatically as the document grows past 999 lines. The number of the line
the cursor is on is highlighted, and the text simply shifts right to make room.

Like syntax coloring, line numbers **switch on automatically when you open a BASIC-source file**
(`.bas` / `.basl` / `.bl` / `.bas.txt`) and off for anything else — so opening BASIC gives you both
colors and numbers at once. Either can still be toggled by hand afterward from the Edit menu.

## Word wrap

An optional **soft word wrap** (Edit menu → *Word Wrap*, default off). When on, a line that's wider
than the screen is folded at word boundaries across several screen rows for display — the file on
disk is never changed (no newlines are inserted). Instead of scrolling sideways, you see the whole
line stacked. Arrow keys move by the **visual** rows you see, so Up/Down step through a wrapped
line's pieces, and the current line's highlight band covers all of its wrapped rows. Turn it off to
go back to single-row lines with horizontal scrolling.

## Run through BASLOAD

[BASLOAD](https://github.com/stefan-b-jakobsson/basload-rom) is the X16's ROM-resident tool that
turns plain-text BASIC source (label-based, no line numbers — files like `.BASL` / `.BAS` / `.BL`)
into a runnable BASIC program. EDIT can drive the whole edit → run → return loop from a single key.

**Press F5** (or **File ▸ Run BASLOAD**) and EDIT will:

1. **Save** the current file (prompting for a name if it's still untitled).
2. **Hand off** to BASLOAD — it prints `BASLOAD"yourfile"` and feeds `RUN` to BASIC, so the program
   tokenizes and runs. When it ends you're at the BASIC `READY.` prompt.
3. **Arm F8** to reload EDIT. The return uses the **DOS wedge**: F8's KERNAL macro is set to `↑/ED`,
   which loads and runs a tiny root launcher named **`ED`** (`10 LOAD"EDIT.PRG"`). (The `pfkey` API
   can only reprogram F1–F8 and SHIFT+RUN; F8 is used because RUN/STOP is an awkward key to press —
   the emulator maps it to the host Pause key, which most keyboards block.)

**Press F8** at the `READY.` prompt and EDIT restarts, **reopening the same file at the same
cursor line** — it leaves a small `ed.run` note at the root on the way out and consumes it on return
(so nothing lingers, and cold-booting the machine is unaffected).

Notes and requirements:

- EDIT snapshots all the KERNAL function-key macros when it starts and restores them **verbatim** when
  you quit normally (**File ▸ Exit**), so the F8 return-key hijack never lingers at the BASIC prompt and
  any F-keys you'd customized are put back exactly. (F8 only stays armed after an F5 hand-off, which is
  exactly when you want it.)
- Needs a **ROM with BASLOAD and the `pfkey` API (R47+)** and the DOS wedge (both stock on the X16).
- The `ED` launcher is a fixed ~20-byte file at the SD/filesystem root, modeled on XFMGR's `/XT`.
  `run.bat` writes it automatically into `run/` if it's missing; on real hardware, place an `ED`
  launcher that `LOAD`s your `EDIT.PRG` at the root (delete it to have `run.bat` regenerate it).
- The current version assumes your source file and `EDIT.PRG` are in the directory EDIT started in
  (the normal case). A ready-to-run example, `HELLO.BASL`, is included in `run/`.

## Building

Requirements:

- A Java runtime (JRE) — to run the bundled `prog8c.jar` compiler
- The [64tass](https://sourceforge.net/projects/tass64/) assembler

```bat
build.bat                 :: compiles SRC\edit.p8 (+ the misc.ovl / tview.ovl overlays) -> edit.prg
build.bat edcfg.p8        :: the settings program
build.bat install.p8      :: the self-installer
build.bat tools\fktest.p8 :: a one-off diagnostic (stays in build\, never published)
```

Everything the compiler emits — the `.prg`, the `misc.ovl` / `tview.ovl` overlays, the `.asm`
listing and the `.vice-mon-list` symbol file — goes into `build\`, which is gitignored. The project
root stays source-only: no binaries are kept or committed there (the build number auto-increments,
so a tracked `.prg` would churn on every compile). `run.bat`, `dbg.bat` and `dist.bat` all stage
straight out of `build\` (plus the tracked `edit.hlp` help text).

Paths to Java and 64tass are set near the top of `build.bat`; adjust them for your machine.
After a successful build it prints a memory-usage summary (image / variables / slabs and the
free low-RAM headroom below the I/O area).

## Running

```bat
run.bat              :: build, stage into run\, and launch x16emu
```

`run.bat` builds, then stages the runtime files — `edit.prg`, the settings program `edcfg.prg`,
the `misc.ovl` (About) and `tview.ovl` (file viewer) overlays, and the `edit.hlp` help text — into
`run\MSEDIT\`, while `run\` itself becomes the emulator's host filesystem root (so sample files
there are visible to Open/Save), and boots straight into the editor. The emulator path comes from
`LOCAL.BAT` — point `%x16%` at your `x16emu` install.

On hardware, run `dist.bat` and copy the files it stages (`install.prg` plus `edit.prg`,
`edcfg.prg`, `misc.ovl`, `tview.ovl`, `edit.hlp`) into one folder on the SD card, then `CD` into it
and `^INSTALL`. The installer creates `/MSEDIT`, copies the programs in and writes the `/ED`
launcher, so the editor starts from anywhere with `^/ED`.

## Debugging

`dbg.bat` is the debug-mode twin of `run.bat`: it launches [Box16](https://github.com/indigodarkwolf/box16)
instead of x16emu and hands it the `build\edit.vice-mon-list` that `prog8c` emits alongside the
compiled program. That is a VICE label file, so every prog8 symbol (`p8b_main:p8s_ed_pgdn`, …) shows up by
name in Box16's disassembly, breakpoint and memory views — including the banked-RAM views, which
is where the document arena, the filelist (bank 6), the clipboard (bank 7) and the `misc.ovl`
(bank 8) and `tview.ovl` (bank 9) code overlays live.

```bat
dbg.bat              :: build, then launch under Box16 with symbols
dbg.bat -n           :: skip the rebuild, launch the existing edit.prg
dbg.bat -b ae1       :: break on startup at $0AE1 (main.start)
```

Point `%box16%` in `LOCAL.BAT` at your Box16 install. In the emulator: **F12** break into the
debugger, **F9** breakpoint at the current position, **F11** step into, **F10** step over.

Addresses for `-b` come from `build\edit.vice-mon-list`. Note that a *block* label there is the block's
variable area, not its code — `.p8b_main` is `$825`, the same address as `p8v_filename`; the code
entry is `.p8b_main:p8s_start` at `$0AE1`.

A few Box16 quirks are worked around in `dbg.bat`, and each one makes working symbols look broken:

- `-joy1` is accepted by x16emu but **rejected by Box16**, which exits immediately. Not passed.
- `-stds` loads the ROM labels (`kernal.sym`, `basic.sym`, …) from the folder holding the `rom.bin`
  in use, and Box16 ships none. `dbg.bat` therefore points `-rom` at the x16emu folder, which has
  all 13 — and whose `rom.bin` is byte-identical to Box16's, so behaviour is unchanged.
- `-scale` does *not* resize the window (it is a render setting). At Box16's default 658×558 the
  CPU and stack panels are drawn on top of the disassembly listing, hiding the symbol column, so
  `dbgwin.ps1` enlarges the window after launch. Arrange the panels once and Box16 saves the layout.
- EDIT idles inside a KERNAL key-wait, so a bare **F12** usually stops in ROM rather than in our
  code. Use `-b`, or type an EDIT address into the disassembler's address box.

## Project layout

| Path | What it is |
| --- | --- |
| `SRC/edit.p8` | The editor: UI, menus, input, editing, search/replace, file picker |
| `SRC/edoc.p8` | Document model — lines stored in banked RAM, load / save to disk |
| `SRC/xarena.p8` | Banked-RAM arena allocator backing the document store and undo history |
| `SRC/syntax.p8` | BASIC syntax highlighter (keyword table + per-line classifier) |
| `build.bat` | Compile to `edit.prg` |
| `run.bat` | Build + launch in the emulator |
| `dbg.bat` | Build + launch under Box16 with prog8 symbols loaded |
| `dbgwin.ps1` | Enlarges the Box16 window so its debugger panels are usable |
| `docs/` | Prog8 and X16 reference material used while building |

## License

Open source under the **MIT License** — free to use, study, modify and redistribute.
See `LICENSE` for the full text.
