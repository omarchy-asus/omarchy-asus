// Queue logic of Service.qml, extracted between the queue-begin/queue-end markers.
// Run: node tests/queue.test.js
const fs = require("fs"), assert = require("assert");
const src = fs.readFileSync(process.argv[2] || require("path").join(__dirname, "..", "Service.qml"), "utf8");
const body = src.slice(src.indexOf("// queue-begin"), src.indexOf("// queue-end"));
const { enqueue } = new Function(body + "\nreturn { enqueue };")();
const H = "g16ctl";
const run = cmds => cmds.reduce((q, c) => enqueue(q, [H, ...c]), []).map(a => a.slice(1).join(" "));
// Reported case: ac low, both off, ac high -> AC must end HIGH.
assert.deepStrictEqual(run([["kbd-level","ac","low"],["kbd-level","both","off"],["kbd-level","ac","high"]]),
  ["kbd-level both off", "kbd-level ac high"]);
// both supersedes earlier narrower scopes.
assert.deepStrictEqual(run([["kbd-level","ac","low"],["kbd-level","battery","med"],["kbd-level","both","off"]]),
  ["kbd-level both off"]);
// Same setting coalesces and moves to the back; unrelated kept in order.
assert.deepStrictEqual(run([["slash-brightness","10"],["winlock-mode","unlock"],["slash-brightness","200"]]),
  ["winlock-mode unlock", "slash-brightness 200"]);
// Distinct flags are distinct settings.
assert.deepStrictEqual(run([["slash-flag","ShowOnBoot","true"],["slash-flag","ShowOnSleep","false"]]),
  ["slash-flag ShowOnBoot true", "slash-flag ShowOnSleep false"]);
console.log("queue tests ok");
