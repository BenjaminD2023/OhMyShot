import { LaunchProps } from "@raycast/api";
import { runCommand } from "./ohmyshot";

export default async function Command(props: LaunchProps<{ arguments: { linebreaks?: string } }>) {
  await runCommand("capture-text", { linebreaks: props.arguments.linebreaks });
}
