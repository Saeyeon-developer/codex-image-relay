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

.PARAMETER Retries
  How many times a transient Codex failure (model at capacity / server overloaded, rate limit,
  5xx-style server error) is retried with a fresh `codex exec`. Default 2. Other errors are never retried.

.PARAMETER RetryDelaySec
  Wait before the first retry, in seconds; doubles on each further retry. Default 20.

.PARAMETER CodexExe
  For testing only: run this executable (for example a fake .cmd that prints canned JSONL)
  instead of the bundled codex.exe.

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
  - Output: success prints `OK <path> (...)`; failure prints exactly one `FAIL <reason>` line to stdout,
    the details to stderr, and exits 1. Each retry prints `retry <n>/<Retries> after <s>s: <reason>`.
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
  [int]$TimeoutSec = 600,
  [ValidateRange(0, 10)][int]$Retries = 2,
  [ValidateRange(0, 3600)][int]$RetryDelaySec = 20,
  [string]$CodexExe
)

$ErrorActionPreference = 'Stop'

# Final failure: one parseable line on stdout (`FAIL <reason>`, independent of the stderr code page),
# then the details on stderr, exit code 1.
function Stop-Relay([string]$Reason, [string[]]$Detail = @()) {
  $one = (($Reason -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
  if (-not $one) { $one = 'unknown error' }
  Write-Output "FAIL $one"
  $ErrorActionPreference = 'Continue'
  Write-Error ((@($Reason) + @($Detail | Where-Object { $_ })) -join "`n")
  exit 1
}

trap { Stop-Relay $_.Exception.Message }

if (-not $Prompt -and $PromptFile) {
  if (-not (Test-Path -LiteralPath $PromptFile)) { Stop-Relay "Prompt file not found: $PromptFile" }
  $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
}
if (-not $Prompt) { Stop-Relay 'Provide -Prompt or -PromptFile.' }

$modeModel = @{ Final = @('gpt-6-luna', 'low'); Draft = @('gpt-6.1-sol', 'high') }
if (-not $Model) { $Model = $modeModel[$PromptMode][0] }
if (-not $Effort) { $Effort = $modeModel[$PromptMode][1] }

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }

if ($CodexExe) {
  if (-not (Test-Path -LiteralPath $CodexExe)) { Stop-Relay "Codex executable not found: $CodexExe" }
  $codexPath = (Resolve-Path -LiteralPath $CodexExe).Path
} else {
  # Locate newest bundled codex.exe (folder name changes with app updates)
  $codex = Get-ChildItem "$env:LOCALAPPDATA\OpenAI\Codex\bin\*\codex.exe" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $codex) { Stop-Relay 'codex.exe not found. Is the Codex desktop app installed?' }
  $codexPath = $codex.FullName
}

# "-Reference a.png,b.png" arrives as one string when called via `powershell -File`; split it.
$Reference = @($Reference | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$refs = @()
foreach ($r in $Reference) {
  if (-not (Test-Path -LiteralPath $r)) { Stop-Relay "Reference not found: $r" }
  $refs += (Resolve-Path -LiteralPath $r).Path
}

$ErrorActionPreference = 'Continue'   # codex writes status to stderr
$login = & $codexPath login status 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
if ($login -match 'not logged in' -or $login -notmatch 'logged in') { Stop-Relay "Codex is not logged in: $($login.Trim())" }

$outFull = [System.IO.Path]::GetFullPath($Output)
$outDir = Split-Path $outFull -Parent
$metaFull = [System.IO.Path]::ChangeExtension($outFull, '.json')
New-Item -ItemType Directory -Force $outDir | Out-Null

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

# Codex sometimes reports an API error as a JSON string ({"type":"error","status":400,"error":{"message":...}}).
# Return the human-readable message.
function Get-CodexMessage([string]$m) {
  $t = "$m".Trim()
  if ($t.StartsWith('{')) {
    try {
      $o = $t | ConvertFrom-Json
      $inner = $null
      if ($o.error -and $o.error.message) { $inner = $o.error.message } elseif ($o.message) { $inner = $o.message }
      if ($inner) {
        if ($o.status) { return "$inner (HTTP $($o.status))" }
        return "$inner"
      }
    } catch { }
  }
  return $t
}

# Transient = worth a fresh `codex exec` after a pause. Known permanent errors win over transient words.
function Test-Transient([string]$text) {
  if (-not $text) { return $false }
  $permanent = 'not logged in|log ?in again|unauthori[sz]ed|\b40[13]\b|"status":\s*40[0-4]|forbidden|invalid_request|' +
    'not supported|unknown feature flag|content polic|safety|moderation|refus|violat|usage limit|quota|billing|credits'
  if ($text -match $permanent) { return $false }
  $transient = 'at capacity|overloaded|server_overloaded|rate[ _-]?limit|too many requests|\b429\b|' +
    '"status":\s*5\d\d|\b50[0-4]\b|internal server error|bad gateway|service unavailable|gateway time-?out|' +
    'temporarily unavailable|try again later|stream disconnected|connection (reset|closed|aborted)'
  return ($text -match $transient)
}

# One `codex exec` run: returns exit code, raw output and the parsed JSONL event stream.
function Invoke-Codex {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $codexPath
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
  try {
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
  } catch { }   # the process may already have exited; its output says why
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    try { $proc.Kill() } catch { }
    return @{ TimedOut = $true; ExitCode = -1; Stderr = ''; Errors = @(); ThreadId = $null; LastMessage = $null; Usage = $null }
  }
  $proc.WaitForExit()   # flush async readers
  $res = @{ TimedOut = $false; ExitCode = $proc.ExitCode; Stderr = "$($stderrTask.Result)"
    ThreadId = $null; LastMessage = $null; Usage = $null; Errors = @() }

  # JSONL events: thread.started, item.completed (agent_message), turn.completed (usage),
  # errors: {"type":"error","message":...} and {"type":"turn.failed","error":{"message":...}}.
  # (item.completed with item.type "error" is a warning and is ignored.)
  foreach ($line in ("$($stdoutTask.Result)" -split "`r?`n")) {
    if (-not $line.Trim().StartsWith('{')) { continue }
    try { $ev = $line | ConvertFrom-Json } catch { continue }
    switch ($ev.type) {
      'thread.started' { $res.ThreadId = $ev.thread_id }
      'item.completed' { if ($ev.item.type -eq 'agent_message') { $res.LastMessage = $ev.item.text } }
      'turn.completed' { $res.Usage = $ev.usage; if ($ev.error -and $ev.error.message) { $res.Errors += "$($ev.error.message)" } }
      'turn.failed'    { if ($ev.error.message) { $res.Errors += "$($ev.error.message)" } else { $res.Errors += 'turn failed' } }
      'error'          { if ($ev.message) { $res.Errors += "$($ev.message)" } }
      default          { if ($ev.error -and $ev.error.message) { $res.Errors += "$($ev.error.message)" } }
    }
  }
  $res.Errors = @($res.Errors | Select-Object -Unique)
  return $res
}

$attempt = 0
while ($true) {
  $run = Invoke-Codex
  if ($run.TimedOut) { Stop-Relay "Timed out after $TimeoutSec s." }

  $why = $null; $gen = $null
  if ($run.ExitCode -ne 0) {
    $why = "codex exited with code $($run.ExitCode)."
  } elseif (-not $run.ThreadId) {
    $why = 'No thread id in codex output; cannot locate the generated image safely.'
  } else {
    # Take the image from this run's own thread folder (race-free when runs overlap)
    $genDir = Join-Path $codexHome "generated_images\$($run.ThreadId)"
    $gen = Get-ChildItem -LiteralPath $genDir -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $gen) { $why = "No image produced (looked in $genDir)." }
  }
  if (-not $why) { break }

  $stderrLines = @(($run.Stderr -split "`r?`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
  $reason = if ($run.Errors.Count) { Get-CodexMessage $run.Errors[-1] } else { $why }
  $classify = if ($run.Errors.Count) { $run.Errors -join "`n" } else { $stderrLines -join "`n" }
  if ((Test-Transient $classify) -and $attempt -lt $Retries) {
    $attempt++
    $delay = $RetryDelaySec * [math]::Pow(2, $attempt - 1)
    Write-Host "retry $attempt/$Retries after ${delay}s: $reason"
    Start-Sleep -Seconds $delay
    continue
  }
  if ($attempt) { $reason = "$reason (after $($attempt + 1) attempts)" }
  $detail = @($why) + @($run.Errors) + @($run.LastMessage) + @($stderrLines | Select-Object -Last 20)
  Stop-Relay $reason $detail
}

$threadId = $run.ThreadId; $lastMessage = $run.LastMessage; $usage = $run.Usage
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
  attempts     = $attempt + 1
  started_at   = $start.ToString('o')
  seconds      = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
}
$json = $meta | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($metaFull, $json, (New-Object Text.UTF8Encoding($false)))

Write-Output "OK $outFull (${w}x${h}, $((Get-Item $outFull).Length) bytes, $($meta.seconds)s, $Model/$Effort)"
