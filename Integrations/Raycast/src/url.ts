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

export interface RegionParameters {
  x?: string;
  y?: string;
  width?: string;
  height?: string;
  display?: string;
}

function regionQuery(region: RegionParameters): Record<string, string | undefined> {
  return {
    x: region.x,
    y: region.y,
    width: region.width,
    height: region.height,
    display: region.display,
  };
}

export function annotateAreaURL(scheme: string, region: RegionParameters = {}): string {
  return commandURL(scheme, "annotate-area", regionQuery(region));
}

export function translateAreaURL(scheme: string, region: RegionParameters = {}): string {
  return commandURL(scheme, "translate-area", regionQuery(region));
}

export function pickColorURL(scheme: string): string {
  return commandURL(scheme, "pick-color");
}

export function measureURL(scheme: string): string {
  return commandURL(scheme, "measure");
}

export function drawOnScreenURL(scheme: string): string {
  return commandURL(scheme, "draw-on-screen");
}

export function saveReplayURL(scheme: string): string {
  return commandURL(scheme, "save-replay");
}
