import { LaunchProps } from "@raycast/api";
import { runCommand } from "./ohmyshot";

export default async function Command(props: LaunchProps<{ arguments: { autoscroll?: string } }>) {
  await runCommand("scrolling-capture", { autoscroll: props.arguments.autoscroll });
}
