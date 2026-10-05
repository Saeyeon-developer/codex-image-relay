---
name: codex-image-relay
description: Generate or edit raster images (PNG) from an agent that has no image generation of its own (e.g. Claude Code) by relaying to the OpenAI Codex desktop app's built-in GPT image tool through the user's ChatGPT login, with no API key. Windows only. Use when the user asks to create, draw, render or edit an image, illustration, character sheet, comic/webtoon panel, mockup or other bitmap, optionally from reference images.
---

# codex-image-relay

`imagen.ps1` (next to this file) sends one image request to the Codex desktop app's built-in image tool and copies the result to the path you choose. Codex runs stripped down: no shell, no files, no skills, no MCP. It only calls the image tool.

## Before the first call

1. This works only on **Windows** with the **Codex desktop app** installed and signed in. The script finds `codex.exe` under `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\` and exits with code 1 if it is missing or signed out. Do not try to install or sign in to Codex for the user; tell them what is missing.
2. Each image counts against the user's ChatGPT/Codex plan usage. Do not generate more images than the task needs, and do not regenerate in a loop.

## Call it

Write the prompt to a UTF-8 text file and pass `-PromptFile`. This avoids shell quoting problems with long or non-English prompts.

From a POSIX shell (Claude Code's Bash tool, Git Bash):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<this skill dir>/imagen.ps1" -PromptFile prompt.txt -Output out/panel01.png -PromptMode Final -Orientation portrait
```

From PowerShell:

```powershell
& "<this skill dir>\imagen.ps1" -PromptFile prompt.txt -Output out\panel01.png -PromptMode Final -Orientation portrait
```

| Parameter | Values | Notes |
|---|---|---|
| `-PromptFile` / `-Prompt` | path / text | One of the two is required. |
| `-Output` | path ending in `.png` | Required. Parent folders are created. Overwrites an existing file. |
| `-PromptMode` | `Final`, `Draft` (default) | See below. |
| `-Orientation` | `auto` (default), `portrait`, `landscape`, `square` | Coarse hint only. For a specific ratio, write it in the prompt instead (see below) and keep `auto`. |
| `-Reference` | `a.png,b.png` | Optional reference images, attached in order as image 1, image 2, and so on. |
| `-Model`, `-Effort` | Codex model slug, `low`…`max` | Overrides the mode's Codex agent model. This does not change the image model. |
| `-TimeoutSec` | default `600` | Per Codex run. |
| `-Retries` | default `2` | Retries for transient Codex failures (model at capacity / overloaded, rate limit, 5xx). |
| `-RetryDelaySec` | default `20` | Wait before the first retry; doubles each retry. |
| `-CodexExe` | path | Testing only: a fake codex executable. |

### Choose the mode

- **`Final`**: use this when you wrote a complete image prompt yourself. Codex passes it to the image tool word for word using a light model (`gpt-6-luna`, low effort). This is the faster and cheaper path, so prefer it.
- **`Draft`**: use this when you only have a rough brief. Codex writes the image prompt itself with a heavy model (`gpt-6.1-sol`, high effort). The prompt it used is saved in the sidecar JSON as `prompt_used`.

A good `Final` prompt states the subject, composition and framing, style and medium, lighting and colour, and any exact visible text in quotes. When you attach references, state the role of each one (for example "Image 1: keep this character's face, hair and outfit. Image 2: use only the colour palette."). Ask for "no text" if you will add lettering later.

## Read the result

- One generation usually takes **45 to 100 seconds**. Set your tool timeout to at least 10 minutes. To make several images, run the calls in parallel or in the background. Concurrent runs are safe because each run reads only its own Codex thread folder.
- On success the script exits 0 and prints one line:
  `OK <absolute path> (<W>x<H>, <bytes> bytes, <seconds>s, <model>/<effort>)`
- It also writes `<output>.json` next to the image. It holds the prompt, `prompt_used`, references, orientation, agent model, Codex `thread_id`, token `usage` and elapsed time. Keep it if you might regenerate or compare versions later.
- On failure the script exits 1 and prints exactly one stdout line `FAIL <reason>` (Codex error, sign-in, missing reference, no image produced); details go to stderr, which may be in the console code page, so read the `FAIL` line. Report it to the user.
- Transient Codex failures (`Selected model is at capacity`, overloaded, rate limit, 5xx) are already retried by the script (`-Retries`, default 2, with `-RetryDelaySec` 20s doubling); each retry prints `retry <n>/<max> after <s>s: <reason>`. If it still fails with such a reason, wait a few minutes before one more try. Never retry other failures (refusal, bad arguments, sign-in) without changing something.
- Look at the image (open or view the PNG) before you call it done. Check people, faces, hands, exact text and consistency with the references. To fix one problem, run again with a corrected prompt or with the previous result as a reference.

## Limits

- You cannot choose the image model or quality.
- **Aspect ratio follows the prompt.** State it in the first line, for example "The whole image is exactly 4:5 (slightly taller than wide)." and keep `-Orientation auto`. The pixel count stays near 1.57 MP, so the ratio decides the size: observed 4:5 → 1122x1402, 2:1 → 1774x887, 2.4:1 → 1942x809, portrait → 1024x1536. For an exact pixel size, request the ratio and resize afterwards.
- This script does not offer a transparent-background option.
- Default Codex agent models are `gpt-6-luna` (Final) and `gpt-6.1-sol` (Draft). If the user's account lacks them, run `codex debug models` with the bundled `codex.exe` to list the available slugs, then pass `-Model`.
- The lean mode depends on Codex feature-flag names. If a Codex update renames one, the run fails with `Unknown feature flag: <name>`. Remove or rename that entry in the `--disable` list in `imagen.ps1`.
