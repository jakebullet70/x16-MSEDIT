# EDIT — a text editor for the Commander X16

A small, full-screen text editor for the **Commander X16**, styled after the classic
**MS-DOS EDIT**: a menu bar up top, dropdown menus, a status line at the bottom, and
the whole document held in **banked RAM**.

Written in [prog8](https://prog8.readthedocs.io/). Runs on real X16 hardware and in the
`x16emu` emulator, in both 80-column and 40-column text modes.

> **Version 0.9.0** · © sadLogic 2026 · Open source

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
| Ctrl+Z | Undo |
| Ctrl+U | Redo |

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
| F1 | About |

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
  64 steps deep), so a deep history costs no scarce low RAM. A Replace-all or paste that changes
  more than 64 lines at once is the one case that can't be fully tracked, so it clears history.
- **A fresh edit clears the redo stack** — the usual editor behaviour.
- **History is cleared only when the whole document is replaced** — starting a **New** document
  or **Opening** a file. After that, Ctrl+Z reports *"Nothing to undo."*

## Syntax coloring

For BASIC source, EDIT can highlight X16 BASIC **keywords**, **strings**, **numbers**, leading
**line numbers**, and `REM` **comments** (shown in green). Toggle it from the **Edit** menu
(*Syntax Color*). Coloring is purely a display layer — it never changes the bytes on disk — and
because BASIC lines are self-contained, only the rows actually on screen are re-colored, so it
stays out of the way while you scroll.

**Auto-detection on open:** coloring is **off by default**, and is switched on automatically when
you open a BASIC-source file — any name ending in **`.bas`**, **`.basl`**, **`.bl`**, or
**`.bas.txt`** (case-insensitive). Opening anything else switches it back off. You can always
override with the Edit-menu toggle.

## Building

Requirements:

- A Java runtime (JRE) — to run the bundled `prog8c.jar` compiler
- The [64tass](https://sourceforge.net/projects/tass64/) assembler

```bat
build.bat            :: compiles SRC\edit.p8 -> edit.prg
build.bat edit.p8    :: same, explicit source
```

Paths to Java and 64tass are set near the top of `build.bat`; adjust them for your machine.
After a successful build it prints a memory-usage summary (image / variables / slabs and the
free low-RAM headroom below the I/O area).

## Running

```bat
run.bat              :: build, stage into run\, and launch x16emu
```

`run.bat` copies the fresh `edit.prg` into the `run\` folder (which becomes the emulator's
host filesystem root, so sample files there are visible to Open/Save) and boots straight into
the editor. The emulator path comes from `LOCAL.BAT` — point `%x16%` at your `x16emu` install.

On hardware, copy `edit.prg` to your SD card and `LOAD"EDIT.PRG"` / `RUN`.

## Project layout

| Path | What it is |
| --- | --- |
| `SRC/edit.p8` | The editor: UI, menus, input, editing, search/replace, file picker |
| `SRC/edoc.p8` | Document model — lines stored in banked RAM, load / save to disk |
| `SRC/xarena.p8` | Banked-RAM arena allocator backing the document store and undo history |
| `SRC/syntax.p8` | BASIC syntax highlighter (keyword table + per-line classifier) |
| `build.bat` | Compile to `edit.prg` |
| `run.bat` | Build + launch in the emulator |
| `docs/` | Prog8 and X16 reference material used while building |

## License

Open source under the **MIT License** — free to use, study, modify and redistribute.
See `LICENSE` for the full text.
