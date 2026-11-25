# Meeting Minutes plug-in

Connects your assistant to the **Meeting Minutes** Mac app, so it can work with the meetings kept on your own Mac. The app is a separate download and must be installed first.

## Install

You need Claude Code and the Meeting Minutes Mac app. In your terminal, add the marketplace once, then install the plug-in:

```
claude plugin marketplace add ag3ntlab-ai/meeting-minutes-plugin
claude plugin install meeting-minutes@ag3ntlab
```

Or do the same from inside a Claude Code session:

```
/plugin marketplace add ag3ntlab-ai/meeting-minutes-plugin
/plugin install meeting-minutes@ag3ntlab
```

## What it starts

The plug-in holds one small shell script. When the assistant starts, the script looks for the Meeting Minutes app in `/Applications` or `~/Applications` and runs the helper program that ships inside that app: `/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp`. The plug-in installs nothing on your Mac. The app answers the handshake and lists its own tools, so the list matches the version of the app you have.

If the app is closed, the first call starts it in the background, without a window.

If the app is not installed, the assistant gets a clear "not installed" error instead of a hang.

## What data it sends

The plug-in sends nothing over the network. It has no server and no network code. Responses from the app go to your chosen assistant, including meeting text when the assistant asks for it. That assistant handles the responses under its own terms.

Read the app's [privacy policy](https://ag3ntlab.ai/meeting-minutes/privacy).

## Untrusted content

Each response separates `meta` (data from the app) from `content` (text from meetings and people). Meeting text is returned as data in `content`, never as instructions. The description of each tool says this too. Your assistant must treat it as untrusted: a sentence in a meeting can look like an order.

## How long commands take

While an import runs, other commands wait for it to finish: about 1.8 s per GiB of audio (another command waited 1.78 s during a synthetic 1 GiB import). The assistant waits up to 120 s for an import.

Finishing a 2-hour recording takes about 90 s for mixing and queuing (90.02 s measured). The assistant waits up to 240 s for this command.

Reads wait up to 30 s; other writes wait up to 60 s. These limits are set by the app. The times above were measured on a busy test Mac with synthetic audio (Meeting Minutes build 42).

## If an import is interrupted

If the app stops during an import, the import is resumed the next time the app starts. The app records this in its Journal: `Resumed importing “<file name>”`.

## Manual setup in Codex

With the Meeting Minutes app installed, add its helper to Codex CLI:

```
codex mcp add meeting-minutes -- "/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp"
```

## Manual setup in ChatGPT Desktop

In ChatGPT Desktop, go to Settings › MCP servers and add a STDIO server whose command is `/Applications/Meeting Minutes.app/Contents/MacOS/mm-mcp`.

The OpenAI page read on 15 November describes this setup without naming macOS. This setup is not yet tested by us on macOS. If the option is missing in your version, it is not available.

## Using ssh or tmux

The app only accepts an assistant running as the same user in that user's graphical session. An assistant started through ssh, or in a tmux session started through ssh, is refused with:

> Client refused: different user, or client outside the user’s graphical session and remote agents disabled.

To allow this, turn on “Allow agents that connect to this Mac remotely” in Settings › Automation. This setting is available only while the main access switch is on.

## Turning access off

In the Meeting Minutes app, go to Settings › Automation › “Allow external agent plugin”. Turn this switch off and the assistant loses access at once. Everything the assistant does is listed in the Journal.

## Licence

MIT, see `LICENSE`. Published by ag3ntlab.
