# OhMyShot for Raycast

Raycast commands for [OhMyShot](../../README.md). Each one sends an `ohmyshot://` URL command. The first one makes
OhMyShot ask once whether it may be controlled: the request names Raycast, or command-line tools when the URL reaches
OhMyShot through `open`. You can change your answer later in OhMyShot's Settings › Automation.

The commands and what they send are listed in [Docs/automation.md](../../Docs/automation.md#raycast).

## Develop

```sh
npm install
npm run dev     # Raycast lists the commands while this runs
npm test        # the URL encoding
npm run lint
```

The extension's App preference chooses between OhMyShot (`ohmyshot://`) and a Debug build, OhMyShot Dev
(`ohmyshot-dev://`).

Before publishing, set `author` in `package.json` to your Raycast username. `ray lint` checks it against Raycast's
servers.

## License

The files in this folder are MIT-licensed, as the Raycast Store requires. The rest of OhMyShot is GPL-3.0.
