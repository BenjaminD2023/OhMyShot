import { runCommand } from "./ohmyshot";

export default async function Command() {
  await runCommand("toggle-desktop-icons");
}
