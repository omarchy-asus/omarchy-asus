// Panel.qml's Slash-grid cursor (nextCursor), extracted between the
// cursor-begin/cursor-end markers. Run: node tests/cursor.test.js
const fs = require("fs"), assert = require("assert"), path = require("path");
const src = fs.readFileSync(process.argv[2] || path.join(__dirname, "..", "Panel.qml"), "utf8");
const body = src.slice(src.indexOf("// cursor-begin"), src.indexOf("// cursor-end"));
const { nextCursor } = new Function(body + "\nreturn { nextCursor };")();
const N = 16, C = 3; // 16 patterns, 3 columns: rows 0-2, 3-5, ..., 15 alone on the last row
const move = (cur, dx, dy, current = 4) => nextCursor(cur, dx, dy, N, C, current);
// The first key lands on the current pattern, whatever the direction.
assert.strictEqual(move(-1, 1, 0, 4), 4);
assert.strictEqual(move(-1, 0, -1, 0), 0);
// Left/right step one cell and run on across rows.
assert.strictEqual(move(4, 1, 0), 5);
assert.strictEqual(move(5, 1, 0), 6);
assert.strictEqual(move(6, -1, 0), 5);
// ... and stop at the ends.
assert.strictEqual(move(0, -1, 0), 0);
assert.strictEqual(move(15, 1, 0), 15);
// Up/down move a row, and stay put rather than leave the grid.
assert.strictEqual(move(4, 0, 1), 7);
assert.strictEqual(move(4, 0, -1), 1);
assert.strictEqual(move(1, 0, -1), 1);
assert.strictEqual(move(13, 0, 1), 13); // no cell below 13 (the last row has only 15)
assert.strictEqual(move(12, 0, 1), 15);
// Walk the whole grid with Right: every pattern is reachable.
let c = -1, seen = new Set();
c = move(c, 1, 0, 0); seen.add(c);
for (let i = 0; i < 20; i++) { c = move(c, 1, 0); seen.add(c); }
assert.strictEqual(seen.size, N);
// An empty grid has no cursor; a stale cursor beyond the grid re-lands on the current one.
assert.strictEqual(nextCursor(3, 1, 0, 0, C, 0), -1);
assert.strictEqual(nextCursor(40, 1, 0, N, C, 2), 2);
console.log("cursor tests ok");
