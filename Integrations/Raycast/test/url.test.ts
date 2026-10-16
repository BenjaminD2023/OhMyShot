import assert from "node:assert/strict";
import { test } from "node:test";
import { commandURL } from "../src/url.ts";

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
