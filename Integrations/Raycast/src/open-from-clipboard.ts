import { runCommand } from "./ohmyshot";

export default async function Command() {
  await runCommand("open-from-clipboard");
}
