Core cases (should all work)

Type on a line → Ctrl+Z → the whole line's edits revert at once (per-line: one undo undoes the whole typing session on that line, not one char). Ctrl+U re-applies. (I verified this — abcdef → empty → abcdef.)

Enter (split a line) → Ctrl+Z → the two lines rejoin into one. (Verified.)

Backspace at column 0 (join to previous line) → Ctrl+Z → the line splits back apart, cursor/content restored.

Delete key at end of line (pulls next line up) → Ctrl+Z → the next line drops back down.

Delete Line / Ctrl+K → Ctrl+Z → the deleted line comes back at the right row.

Paste a whole line (Ctrl+V or F4 after copying a line) → Ctrl+Z → the pasted line is removed.

Select text (Shift+arrows) then Delete/Backspace → Ctrl+Z → the selection (even spanning several lines) comes back in one undo.

Multi-step: make several edits, press Ctrl+Z repeatedly → they unwind newest-first; then Ctrl+U repeatedly → they redo in order.


Redo invalidation: undo a couple times, then type something new → Redo (Ctrl+U) should now do nothing ("Nothing to redo"). New edits kill the redo stack.

Things to watch closely (most likely to reveal bugs)
After an undo/redo, the cursor lands on the affected line at column 0, and scrolling/line count stay correct (no phantom blank line, no off-by-one row).

Undo a structural op grouped with a content change (e.g. Backspace-join) should restore both the merged line's old text and the re-split line in one Ctrl+Z.

Edit a line, move to another line, come back and undo — should still restore correctly (the snapshot is taken on first edit of a line).

Boundary: undo down to an empty document — it should keep one empty line, never zero.
Depth: more than ~64 undo steps — the oldest silently drop (expected).


Known intentional limitations (NOT bugs)

Save / Open / New clears undo history — expected (the arena is reset/compacted on Save, so snapshots are gone). After Save, Ctrl+Z says "Nothing to undo."

Replace-all clears undo history — not tracked in v1 (it touches many lines).

Multi-line inline paste (a selection-clipboard containing line breaks) clears history — also v1-untracked. A single-line inline paste is undoable.

Undo granularity is per line/op, so one Ctrl+Z reverts a whole line's typing, not a single character — by design.

If any of these misbehave — wrong line restored, cursor jumps, a leftover/blank line, a group that needs two Ctrl+Z, or a crash/garbled screen — tell me the exact steps and I'll fix it.