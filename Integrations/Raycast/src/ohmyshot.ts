import { closeMainWindow, getPreferenceValues, getSelectedFinderItems, open, showHUD } from "@raycast/api";
import { commandURL } from "./url";

interface ExtensionPreferences {
  scheme?: string;
}

/**
 * Runs an OhMyShot command. Raycast's window closes first, so a capture never has it in the picture. The first
 * command makes OhMyShot ask whether it may be controlled.
 */
export async function runCommand(command: string, parameters: Record<string, string | undefined> = {}) {
  const { scheme = "ohmyshot" } = getPreferenceValues<ExtensionPreferences>();
  await closeMainWindow({ clearRootSearch: true });
  try {
    await open(commandURL(scheme, command, parameters));
  } catch {
    await showHUD(scheme === "ohmyshot-dev" ? "OhMyShot Dev isn’t installed" : "OhMyShot isn’t installed");
  }
}

/** The file selected in Finder, when Finder is in front and one is. */
export async function selectedFinderFile(): Promise<string | undefined> {
  try {
    return (await getSelectedFinderItems())[0]?.path;
  } catch {
    return undefined;
  }
}
