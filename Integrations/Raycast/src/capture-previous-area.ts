import { LaunchProps } from "@raycast/api";
import { runCommand } from "./ohmyshot";

export default async function Command(props: LaunchProps<{ arguments: { action?: string } }>) {
  await runCommand("capture-previous-area", { action: props.arguments.action });
}
