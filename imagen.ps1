<#
.SYNOPSIS
  codex-image-relay: generate/edit a still image through the Codex desktop app's built-in image tool,
  using the user's ChatGPT login (no API key). Codex runs in a stripped-down mode that exposes only
  what image generation needs. https://github.com/Saeyeon-developer/codex-image-relay

  Copyright 2026 Saeyeon-developer. Licensed under the Apache License, Version 2.0.

.EXAMPLE
  .\imagen.ps1 -Prompt "A red fox logo on cream background" -Output out\fox.png -Orientation landscape
  .\imagen.ps1 -PromptFile prompt.txt -Reference ref1.png,ref2.png -Output out.png -PromptMode Final

.PARAMETER PromptMode
  Final : the prompt is already finished (written by the calling agent or a person).
          Codex only passes it to the image tool verbatim. Light model: gpt-6-luna / low.
  Draft : the prompt is a rough brief. Codex writes the image prompt itself before generating.
          Heavy model: gpt-6.1-sol / high. (default)
  -Model / -Effort override the mode's model.

.NOTES
  Known Codex limits (do not promise otherwise):
  - The image model and quality cannot be chosen (the built-in tool does not expose them).
    (-Model only picks the Codex agent model that drives the tool, not the image model.)
  - Aspect ratio follows the prompt: state it explicitly (e.g. "The whole image is exactly 4:5") and leave
    -Orientation at auto. The pixel count stays near 1.57 MP, so the ratio decides the size
    (observed: 4:5 -> 1122x1402, 2:1 -> 1774x887, 2.4:1 -> 1942x809, portrait -> 1024x1536).
    Need an exact resolution? Request the ratio, then resize.
  - Prompt text is passed to codex via stdin, so any length and any language is fine.
  - Safe to run in parallel: the image is taken from this run's own Codex thread folder.
  - Writes <output>.json next to the image (prompt, references, model, thread id, final prompt used).
#>
param(
  [string]$Prompt,
  [string]$PromptFile,
  [string[]]$Reference = @(),
  [Parameter(Mandatory = $true)][string]$Output,
  [ValidateSet('landscape', 'portrait', 'square', 'auto')][string]$Orientation = 'auto',
  [ValidateSet('Final', 'Draft')][string]$PromptMode = 'Draft',
  [string]$Model,
  [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$Effort,
  [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'

if (-not $Prompt -and $PromptFile) { $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8 }
if (-not $Prompt) { throw 'Provide -Prompt or -PromptFile.' }

$modeModel = @{ Final = @('gpt-6-luna', 'low'); Draft = @('gpt-6.1-sol', 'high') }
if (-not $Model) { $Model = $modeModel[$PromptMode][0] }
if (-not $Effort) { $Effort = $modeModel[$PromptMode][1] }

# Locate newest bundled codex.exe (folder name changes with app updates)
$codex = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin\*\codex.exe" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $codex) { throw 'codex.exe not found. Is the Codex desktop app installed?' }

$ErrorActionPreference = 'Continue'   # codex writes status to stderr
$login = & $codex.FullName login status 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
if ($login -notmatch 'Logged in') { throw "Codex is not logged in: $login" }

$outFull = [System.IO.Path]::GetFullPath($Output)
$outDir = Split-Path $outFull -Parent
$metaFull = [System.IO.Path]::ChangeExtension($outFull, '.json')
New-Item -ItemType Directory -Force $outDir | Out-Null

# "-Reference a.png,b.png" arrives as one string when called via `powershell -File`; split it.
$Reference = @($Reference | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$refs = @()
foreach ($r in $Reference) {
  if (-not (Test-Path -LiteralPath $r)) { throw "Reference not found: $r" }
  $refs += (Resolve-Path -LiteralPath $r).Path
}

$orient = switch ($Orientation) {
  'landscape' { 'Make it a LANDSCAPE (wide) image.' }
  'portrait'  { 'Make it a PORTRAIT (tall) image.' }
  'square'    { 'Make it a SQUARE image.' }
  default     { '' }
}
$refNote = if ($refs.Count) { "The attached image(s) are references, numbered in the order attached (image 1, image 2, ...); follow the roles given in the prompt." } else { '' }

if ($PromptMode -eq 'Final') {
  $full = @"
Call the image generation tool exactly once to create ONE image.
Pass the prompt between the BEGIN/END markers to the tool verbatim. Do not rewrite, translate, shorten, or add to it.
$orient
$refNote
Do not run shell commands and do not create files. When the tool returns, reply with: DONE

----- BEGIN PROMPT -----
$Prompt
----- END PROMPT -----
"@
} else {
  $full = @"
Create ONE image with the image generation tool from the brief between the BEGIN/END markers.
First turn the brief into a strong, specific image prompt: subject, composition and framing, style and medium,
lighting and color, exact visible text (quoted, with placement), and the role of each attached reference image.
Keep any quoted text, names and product labels exactly as given. Then call the image generation tool exactly once with that prompt.
$orient
$refNote
Do not run shell commands and do not create files. When the tool returns, reply with exactly the prompt you sent to the tool, and nothing else.

----- BEGIN BRIEF -----
$Prompt
----- END BRIEF -----
"@
}

# Lean Codex: expose only what image generation needs. Skips the user's config.toml, rules, MCP servers,
# plugins/skills listings and the stock Codex system prompt (replaced by codex-instructions.md).
$leanArgs = @('--ignore-user-config', '--ignore-rules',
  '-c', "model_instructions_file='$PSScriptRoot\codex-instructions.md'",
  '-c', 'include_permissions_instructions=false',
  '-c', 'include_apps_instructions=false',
  '-c', 'include_environment_context=false',
  '-c', 'include_collaboration_mode_instructions=false',
  '-c', 'include_skills_usage_instructions=false',
  '-c', 'include_plugin_usage_instructions=false',
  '-c', 'project_doc_max_bytes=0',
  '-c', 'web_search="disabled"',
  '-c', 'tools.web_search=false')
foreach ($f in @('apps', 'browser_use', 'browser_use_external', 'browser_use_full_cdp_access', 'computer_use',
    'goals', 'guardian_approval', 'hooks', 'in_app_browser', 'multi_agent', 'plugins', 'plugin_sharing',
    'remote_plugin', 'skill_mcp_dependency_install', 'skill_search', 'sleep_tool', 'tool_suggest',
    'tool_call_mcp_elicitation', 'workspace_dependencies', 'worktrees', 'shell_tool', 'unified_exec', 'view_image')) {
  $leanArgs += @('--disable', $f)
}
# Skills are listed in every request; turn off bundled ones and every installed user skill for this run only.
$leanArgs += @('-c', 'skills.bundled.enabled=false')
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$skillFiles = @(Get-ChildItem -Path "$codexHome\skills\*\SKILL.md", "$env:USERPROFILE\.agents\skills\*\SKILL.md" -ErrorAction SilentlyContinue)
if ($skillFiles.Count) {
  $entries = $skillFiles | ForEach-Object { "{path='$($_.FullName -replace '\\', '/')',enabled=false}" }
  $leanArgs += @('-c', "skills.config=[$($entries -join ',')]")
}

$start = Get-Date
$cliArgs = @('exec', '--json', '--skip-git-repo-check', '--sandbox', 'read-only', '-C', $outDir,
  '-m', $Model, '-c', "model_reasoning_effort=`"$Effort`"") + $leanArgs
foreach ($r in $refs) { $cliArgs += @('-i', $r) }
$cliArgs += '-'

function Quote-Arg([string]$a) {
  if ($a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $codex.FullName
$psi.Arguments = ($cliArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$proc = [System.Diagnostics.Process]::Start($psi)
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($full)
$proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
$proc.StandardInput.Close()
if (-not $proc.WaitForExit($TimeoutSec * 1000)) { $proc.Kill(); throw "Timed out after $TimeoutSec s." }
$proc.WaitForExit()   # flush async readers
$stdout = $stdoutTask.Result
$stderr = $stderrTask.Result

# Parse the JSONL event stream: thread id, final agent message, errors, token usage
$threadId = $null; $lastMessage = $null; $usage = $null; $errors = @()
foreach ($line in ($stdout -split "`r?`n")) {
  if (-not $line.Trim().StartsWith('{')) { continue }
  try { $ev = $line | ConvertFrom-Json } catch { continue }
  switch ($ev.type) {
    'thread.started' { $threadId = $ev.thread_id }
    'item.completed' { if ($ev.item.type -eq 'agent_message') { $lastMessage = $ev.item.text } }
    'turn.completed' { $usage = $ev.usage }
    'turn.failed'    { $errors += $ev.error.message }
    'error'          { $errors += $ev.message }
  }
}

$fail = {
  param($why)
  $detail = (@($errors) + @($lastMessage) + @($stderr.Trim())) | Where-Object { $_ } | Select-Object -Last 5
  Write-Error ("$why`n" + ($detail -join "`n"))
  exit 1
}

if ($proc.ExitCode -ne 0) { & $fail "codex exited with code $($proc.ExitCode)." }
if (-not $threadId) { & $fail 'No thread id in codex output; cannot locate the generated image safely.' }

# Take the image from this run's own thread folder (race-free when runs overlap)
$genDir = Join-Path $env:USERPROFILE ".codex\generated_images\$threadId"
$gen = Get-ChildItem -LiteralPath $genDir -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $gen) { & $fail "No image produced (looked in $genDir)." }
Copy-Item -LiteralPath $gen.FullName -Destination $outFull -Force

Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($outFull)
$w = $img.Width; $h = $img.Height
$img.Dispose()

$meta = [ordered]@{
  output       = $outFull
  width        = $w
  height       = $h
  prompt_mode  = $PromptMode
  prompt       = $Prompt
  prompt_used  = if ($PromptMode -eq 'Draft') { $lastMessage } else { $Prompt }
  references   = $refs
  orientation  = $Orientation
  agent_model  = $Model
  agent_effort = $Effort
  thread_id    = $threadId
  source       = $gen.FullName
  usage        = $usage
  started_at   = $start.ToString('o')
  seconds      = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
}
$json = $meta | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($metaFull, $json, (New-Object Text.UTF8Encoding($false)))

Write-Output "OK $outFull (${w}x${h}, $((Get-Item $outFull).Length) bytes, $($meta.seconds)s, $Model/$Effort)"
