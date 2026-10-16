/**
 * The URL of an OhMyShot command: `<scheme>://<command>?<parameters>`, with CleanShot X's command names and
 * parameters. Values are percent-encoded, a space as %20 and a plus as %2B: the app reads the query as
 * URLComponents does, which never turns "+" into a space. Parameters with no value are left out.
 */
export function commandURL(
  scheme: string,
  command: string,
  parameters: Record<string, string | undefined> = {},
): string {
  const query = Object.entries(parameters)
    .filter((entry): entry is [string, string] => entry[1] !== undefined && entry[1] !== "")
    .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`)
    .join("&");
  return `${scheme}://${command}${query ? `?${query}` : ""}`;
}
