import { runCommand, selectedFinderFile } from "./ohmyshot";

/** With nothing selected in Finder, OhMyShot asks for a file. */
export default async function Command() {
  await runCommand("pin", { filepath: await selectedFinderFile() });
}
