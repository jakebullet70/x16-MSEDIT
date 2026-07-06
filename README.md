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

### Search

| Key | Action |
| --- | --- |
| Ctrl+F / F6 | Find |
| Ctrl+G / F3 | Find next |
| Ctrl+R / F8 | Replace |
| Ctrl+J | Go to line |

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
| `SRC/xarena.p8` | Banked-RAM arena allocator backing the document store |
| `build.bat` | Compile to `edit.prg` |
| `run.bat` | Build + launch in the emulator |
| `docs/` | Prog8 and X16 reference material used while building |

## License

Open source under the **MIT License** — free to use, study, modify and redistribute.
See `LICENSE` for the full text.
