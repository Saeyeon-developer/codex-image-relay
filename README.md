# codex-image-relay

[한국어](README.ko.md)

Give any AI coding agent image generation through the **OpenAI Codex desktop app's built-in GPT image tool**, using your ChatGPT login. You do not need an OpenAI API key.

Claude Code, and any other agent that can run a shell command, calls one PowerShell script. Codex starts in a stripped-down mode that exposes only image generation, then the PNG and a JSON record are written where you asked.

![Example: a webtoon panel generated through the relay](examples/webtoon-panel.jpg)

*Made with [`examples/webtoon-panel.prompt.txt`](examples/webtoon-panel.prompt.txt) in `Final` mode, 48 s.*

---

## For AI agents

If a user gave you this repository URL, do this:

1. **Check the platform.** This works only on **Windows** with the **Codex desktop app** installed and signed in. If either is missing, stop and tell the user. Do not install or sign in for them.
2. **Install it as a skill** by cloning into your skills folder. For Claude Code:
   ```bash
   git clone https://github.com/Saeyeon-developer/codex-image-relay ~/.claude/skills/codex-image-relay
   ```
   For agents that read `~/.agents/skills`, clone there instead. You can also run the script straight from any checkout without installing it.
3. **Read [`SKILL.md`](SKILL.md).** It is the complete operating guide: how to call the script, which mode to use, the output format, exit codes and limits.
4. **Make one test image only if the user asked for an image.** Each image uses the user's ChatGPT plan quota.

---

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (built in)
- [Codex desktop app](https://openai.com/codex), signed in with a ChatGPT account. The script uses the `codex.exe` bundled with the app under `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\`. A separately installed `codex` CLI on PATH is not used.
- Image generations count against your ChatGPT/Codex plan usage.

## Usage

```powershell
.\imagen.ps1 -PromptFile prompt.txt -Output out\panel.png -PromptMode Final -Orientation portrait
.\imagen.ps1 -Prompt "A red fox logo on a cream background" -Output out\fox.png -Orientation landscape
.\imagen.ps1 -PromptFile prompt.txt -Reference char.png,style.png -Output out\scene.png -PromptMode Final
```

From bash (for example Claude Code's Bash tool):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File ./imagen.ps1 -PromptFile prompt.txt -Output out/panel.png -PromptMode Final
```

| Parameter | Description |
|---|---|
| `-PromptFile` / `-Prompt` | The prompt. Use a UTF-8 file for long or non-English prompts. |
| `-Output` | Destination PNG path. Required. |
| `-PromptMode` | `Final`: the prompt is finished and is passed to the image tool word for word. `Draft` (default): Codex writes the image prompt from your brief first. |
| `-Orientation` | `auto` (default), `portrait`, `landscape`, `square`. A coarse hint. For a specific ratio, write it in the prompt (see Caveats). |
| `-Reference` | Reference images, attached in order as image 1, image 2, and so on. Describe each one's role in the prompt. |
| `-Model`, `-Effort` | Override the Codex *agent* model for the mode. The image model cannot be chosen. |
| `-TimeoutSec` | Default 600. |

### Prompt modes

| Mode | When to use | Codex agent model |
|---|---|---|
| `Final` | You or your agent already wrote a complete prompt | `gpt-6-luna` / low |
| `Draft` | You only have a rough idea | `gpt-6.1-sol` / high |

The agent model only drives the tool call (plus prompt writing in `Draft`). It does not change how the image looks. Prefer `Final`: it is faster and uses less of your quota.

### Output

- `out\panel.png`: the image.
- `out\panel.json`: the prompt, `prompt_used` (the prompt Codex wrote in `Draft` mode), references, model, Codex `thread_id`, token usage and elapsed time.
- On success, stdout ends with `OK <path> (<W>x<H>, <bytes> bytes, <s>s, <model>/<effort>)` and the exit code is 0. On failure the exit code is 1 and the reason is printed.
- Concurrent runs are safe. Each run takes its image only from its own Codex thread folder (`~/.codex/generated_images/<thread_id>/`).

## Lean mode: why it is cheap

Without changes, `codex exec` sends Codex's full coding-agent context with every model call. That includes the system prompt, permission and environment notes, the list of every installed skill and plugin, and tool definitions for shell, browser, computer use and more. The script turns all of that off **for its own run only**. Your `~/.codex/config.toml` is never modified.

- `--ignore-user-config`, `--ignore-rules`: skip your config.toml, MCP servers and rules.
- `model_instructions_file` → [`codex-instructions.md`](codex-instructions.md): replaces the stock system prompt (about 18k characters) with a three-line relay instruction.
- `include_*_instructions=false`: drops the permission, apps, environment, collaboration-mode, skills and plugin notes.
- Skills: bundled skills are disabled, and every skill in `~/.codex/skills` and `~/.agents/skills` is disabled for this run.
- `--disable …`: turns off browser, computer use, apps, plugins, multi-agent, shell, patching, `view_image`, web search and more.

Measured with the same `Final` prompt, one image each:

| | Model calls | Input tokens (total) |
|---|---|---|
| Stock Codex | 3 | 58,615 |
| Lean (this script) | 2 | **9,179** (−84%) |

What remains is Codex's multi-agent role note (about 2.7k characters) and the tool definitions. No option was found to remove them.

## Caveats

- **Windows only for now.** The script relies on the Codex desktop app's install location on Windows.
- **You cannot pick the image model or quality.** The built-in tool does not expose them.
- **Aspect ratio is set by the prompt, not by a parameter.** Write the ratio explicitly (e.g. "The whole image is exactly 4:5") and keep `-Orientation auto`. The pixel count stays near 1.57 MP, so the ratio decides the size:

  | Requested | Result |
  |---|---|
  | 4:5 | 1122×1402 |
  | 2:1 | 1774×887 |
  | 2.4:1 | 1942×809 |
  | `-Orientation portrait` | 1024×1536 |

  For an exact pixel size, request the ratio and resize afterwards.
- **Default agent models may not be on your plan.** If `gpt-6-luna` or `gpt-6.1-sol` are unavailable, list the models you have with the bundled `codex.exe debug models` and pass `-Model`.
- **Codex updates can break lean mode.** The script disables Codex features by name. If an update renames or removes one, Codex exits with `Unknown feature flag: <name>` and the script fails with exit code 1. It never quietly falls back to the heavy setup. Run `codex.exe features list` and edit the `--disable` list in `imagen.ps1`.
- **Codex sessions are kept.** Each run is a normal (non-ephemeral) Codex session, so it may appear in Codex's history.
- **This is an unofficial tool.** It drives Codex through its public CLI flags. Codex internals can change at any time.

## Troubleshooting

| Message | Fix |
|---|---|
| `codex.exe not found` | Install the Codex desktop app and open it once. |
| `Codex is not logged in` | Open the Codex app and sign in. |
| `Unknown feature flag: …` | A Codex update renamed a feature. See Caveats. |
| `No image produced` | The request may have been refused or failed. The printed log shows Codex's reason. Adjust the prompt. |
| A model error mentioning `gpt-6-luna` / `gpt-6.1-sol` | Pass `-Model <slug>` with a model your plan has. |

## License

[Apache License 2.0](LICENSE)
