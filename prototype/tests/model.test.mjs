import { test } from "node:test";
import assert from "node:assert/strict";
import { initial, reduce, frameTimes } from "../src/model.mjs";
test("countdown cancellation and stale concurrent command", () => {
  let s = reduce(initial(), { type: "start" }, 0);
  assert.equal(s.phase, "countdown");
  assert.equal(reduce(s, { type: "start", expected: 0 }, 1), s);
  s = reduce(s, { type: "cancel" }, 1);
  assert.equal(reduce(s, { type: "tick" }, 5000).phase, "ready");
});
test("record, stop, save and file frame boundaries", () => {
  let s = reduce(initial(), { type: "start" }, 0);
  s = reduce(s, { type: "tick" }, 3000);
  s = reduce(s, { type: "stop" }, 63000);
  s = reduce(s, { type: "tick" }, 65000);
  assert.equal(s.phase, "saved");
  assert.equal(s.takes[0].duration, 60);
  assert.deepEqual(frameTimes(60), [0, 30, 59]);
});
test("end saves before uninstall, blocks further commands, retains takes", () => {
  let s = reduce(initial(), { type: "demo" }, 1000000);
  s = reduce(s, { type: "end" }, 1000000);
  assert.equal(s.phase, "saving");
  assert.equal(reduce(s, { type: "start" }, 1000000), s);
  s = reduce(s, { type: "tick" }, 1002000);
  assert.equal(s.phase, "ending");
  s = reduce(s, { type: "tick" }, 1005000);
  assert.equal(s.phase, "closed");
  assert.equal(s.takes.length, 1);
});
test("save failure preserves end intent and can recover", () => {
  let s = reduce(initial(), { type: "demo" }, 1000000);
  s = reduce(s, { type: "failure" });
  s = reduce(s, { type: "end" }, 1000000);
  s = reduce(s, { type: "tick" }, 1002000);
  assert.equal(s.phase, "save_failed");
  assert.equal(s.endRequested, true);
  s = reduce(s, { type: "retry" }, 1003000);
  s = reduce(s, { type: "tick" }, 1005000);
  assert.equal(s.phase, "ending");
  assert.equal(s.takes.length, 1);
});
test("offline rejects director control but guest can stop locally", () => {
  let s = reduce(initial(), { type: "demo" }, 1000000);
  s = reduce(s, { type: "network" });
  assert.equal(reduce(s, { type: "stop", remote: true }), s);
  assert.equal(reduce(s, { type: "stop", remote: false }).phase, "saving");
});
test("no tracks cannot start; very short sheet deduplicates", () => {
  let s = initial();
  s.tracks = { camera: false, desktop: false };
  assert.equal(reduce(s, { type: "start" }), s);
  assert.deepEqual(frameTimes(0), [0]);
  assert.deepEqual(frameTimes(1), [0]);
});

test("trial locks start on all clients until completion", () => {
  let s = reduce(initial(), { type: "trial" }, 0);
  assert.equal(reduce(s, { type: "start" }, 100), s);
  s = reduce(s, { type: "tick" }, 10000);
  assert.equal(s.phase, "ready");
  assert.equal(s.trialDone, true);
});
test("remote countdown cancels on relay loss", () => {
  let s = reduce(initial(), { type: "start", remote: true }, 0);
  s = reduce(s, { type: "network" }, 100);
  assert.equal(s.phase, "ready");
});
