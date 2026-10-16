import { showHUD } from "@raycast/api";
import { runCommand, selectedFinderFile } from "./ohmyshot";

export default async function Command() {
  const file = await selectedFinderFile();
  if (!file) {
    await showHUD("Select an image in Finder first");
    return;
  }
  await runCommand("capture-text", { filepath: file });
}
