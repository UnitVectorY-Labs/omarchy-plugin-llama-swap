# Llama Swap for Omarchy

An [Omarchy Quattro](https://omarchy.org/) bar plugin for monitoring and controlling a [Llama Swap](https://github.com/mostlygeek/llama-swap) server.

The panel shows active inference requests, lists every configured model in a stable paginated view, and lets you load or unload models with immediate, optimistic switches.

## Requirements

- Omarchy Quattro with shell plugin support
- `bash`, `curl`, `awk`, and GNU coreutils (included with Omarchy)
- A reachable Llama Swap server
- An optional Llama Swap API key when the server requires authentication

The plugin runs inside Omarchy's long-lived Quickshell process with your user permissions. It does not require elevated privileges, install hooks, or a second Quickshell process.

## Install

```sh
omarchy plugin add https://github.com/UnitVectorY-Labs/omarchy-plugin-llama-swap.git --enable
```

The widget is placed in the right bar section by default. Move it with the standard Omarchy command if desired:

```sh
omarchy bar move io.github.unitvectory-labs.llama-swap --section right
```

## Configure

Set the Llama Swap base URL:

```sh
omarchy bar set io.github.unitvectory-labs.llama-swap url https://llama-swap.example.com
```

Authentication is optional. When configured, the token is sent as an `Authorization: Bearer` header. The plugin passes it to the request helper over standard input, so it is never included in process arguments:

```sh
omarchy bar set io.github.unitvectory-labs.llama-swap apiToken YOUR_TOKEN
```

Omarchy persists bar-widget settings in `~/.config/omarchy/shell.json`. The API token is therefore stored as plain text and is readable by the local user account. Use a suitably scoped token and do not use this implementation where local plain-text storage is unacceptable.

Remote responses are bounded before they enter Quickshell: model snapshots are limited to 1 MiB, and each event-stream connection is limited to 2 MiB, 512 data records, and 64 KiB per record. Model/request state is capped as a second layer of protection, and server-provided strings are rendered as plain text.

## Usage

Click the llama icon to open or close the panel. Press Escape or click outside the panel to close it.

- Models retain the same name/ID ordering used by Llama Swap's interface.
- Five models are shown per page; Previous and Next navigate without a scrolling list.
- A model switch moves immediately, while its load or unload operation continues asynchronously.
- Left and right arrow keys change model pages while the panel has focus.

### Connection lifecycle

The plugin is live only while its panel is visible:

1. Opening the panel fetches a current `GET /v1/models` snapshot.
2. It connects to the `/api/events` server-sent event stream and shows the model, endpoint, and elapsed time for active requests.
3. Closing the panel terminates the event process and clears transient request state.

There is no periodic polling or persistent event connection while the panel is closed. A user-requested model load or unload is allowed to finish after the panel closes, then performs one replacement model snapshot.

## API endpoints

The plugin calls these Llama Swap endpoints:

- `GET /v1/models` — list models and load state
- `GET /api/events` — follow active requests while the panel is open
- `GET /upstream/:model/` — load a model, matching Llama Swap's own UI
- `POST /api/models/unload/:model` — unload a model

## Remove

```sh
omarchy plugin remove io.github.unitvectory-labs.llama-swap
```

Removal disables the widget and removes its installed checkout according to Omarchy's standard plugin lifecycle.

## Development

Clone the repository, validate the manifest, and lint both QML entry files against the installed Omarchy shell:

```sh
git clone https://github.com/UnitVectorY-Labs/omarchy-plugin-llama-swap.git
cd omarchy-plugin-llama-swap
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
```

The bounded request helper has a host-independent integration test:

```sh
python3 tests/test_request_helper.py
```

For live development, symlink the checkout under the permanent plugin ID, rescan, and enable it:

```sh
ln -s "$PWD" "$HOME/.config/omarchy/plugins/io.github.unitvectory-labs.llama-swap"
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.unitvectory-labs.llama-swap
```

Files under `~/.config/omarchy/plugins/` hot-reload when saved. Before publishing a change, test click, Escape, shell summon/hide, disable/re-enable, and a shell restart.

## License

[MIT](LICENSE)
