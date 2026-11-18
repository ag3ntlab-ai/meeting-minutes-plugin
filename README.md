# Meeting Minutes plug-in

Connects your assistant to the **Meeting Minutes** Mac app, so it can work with the meetings kept on your own Mac. The app is a separate download and must be installed first.

## What it starts

The plug-in holds one small program, `relay/mm-mcp-relay`, whose source is in `relay-src/`. When the assistant starts, the program looks for the Meeting Minutes app in `/Applications` or `~/Applications`, starts it in the background if needed, and passes the assistant's requests to it over a private socket on your Mac. Nothing else is started, and the plug-in installs nothing. The program lists no tools: the app itself tells the assistant what it can do, so the list always matches the version of the app you have.

If the app is not installed, the assistant gets a clear "not available" error instead of a hang.

## What data it sends

The plug-in sends nothing anywhere. It has no server and no network code. Meeting data stays in the app on your Mac. When you ask the assistant a question, the app returns the answer to the assistant you chose, and that assistant handles it under its own terms. Text that comes from a meeting is handed over as data, never as instructions, and you should still treat it as untrusted content.

## Turning access off

Access is controlled in the Meeting Minutes app, under its settings. Turn the agent access switch off and the assistant loses access at once.

## Licence

MIT, see `LICENSE`. Published by ag3ntlab.
