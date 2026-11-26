import assert from "node:assert/strict";
import { test } from "node:test";
import {
  annotateAreaURL,
  commandURL,
  drawOnScreenURL,
  measureURL,
  pickColorURL,
  saveReplayURL,
  translateAreaURL,
} from "../src/url.ts";

test("a command without parameters is just the scheme and the name", () => {
  assert.equal(commandURL("ohmyshot", "capture-area"), "ohmyshot://capture-area");
});

test("parameters without a value are left out", () => {
  assert.equal(commandURL("ohmyshot", "capture-area", { action: undefined, x: "" }), "ohmyshot://capture-area");
  assert.equal(
    commandURL("ohmyshot-dev", "capture-window", { action: "pin" }),
    "ohmyshot-dev://capture-window?action=pin",
  );
});

test("a path keeps its spaces and plus signs", () => {
  const url = commandURL("ohmyshot", "pin", { filepath: "/Users/me/Desktop/a+b shot.png" });
  assert.equal(url, "ohmyshot://pin?filepath=%2FUsers%2Fme%2FDesktop%2Fa%2Bb%20shot.png");
  assert.equal(new URL(url).searchParams.get("filepath"), "/Users/me/Desktop/a+b shot.png");
});

test("extended OhMyShot commands build expected URLs", () => {
  assert.equal(annotateAreaURL("ohmyshot"), "ohmyshot://annotate-area");
  assert.equal(
    annotateAreaURL("ohmyshot", { x: "10", y: "20", width: "300", height: "200", display: "2" }),
    "ohmyshot://annotate-area?x=10&y=20&width=300&height=200&display=2",
  );
  assert.equal(translateAreaURL("ohmyshot"), "ohmyshot://translate-area");
  assert.equal(
    translateAreaURL("ohmyshot-dev", { display: "1" }),
    "ohmyshot-dev://translate-area?display=1",
  );
  assert.equal(pickColorURL("ohmyshot"), "ohmyshot://pick-color");
  assert.equal(measureURL("ohmyshot"), "ohmyshot://measure");
  assert.equal(drawOnScreenURL("ohmyshot"), "ohmyshot://draw-on-screen");
  assert.equal(saveReplayURL("ohmyshot-dev"), "ohmyshot-dev://save-replay");
});
