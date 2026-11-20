# Programa shell integration for PowerShell (5.1 and 7). Programa starts PowerShell with
# -NoExit -EncodedCommand holding this script, so it runs after your profile and is not subject
# to the script execution policy. It wraps whatever prompt your profile set and, at each prompt,
# reports the working directory (OSC 7), the prompt start and end (OSC 133;A and B) and a title
# naming the directory (OSC 2), like Ghostty's zsh and bash integration.
if ($global:__ProgramaIntegrated) { return }
$global:__ProgramaIntegrated = $true
$global:__ProgramaPrompt = $function:prompt

function global:prompt {
    $esc = [char]27
    $bel = [char]7
    $report = "$esc]133;A$bel"
    $location = $executionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -eq 'FileSystem') {
        $path = $location.ProviderPath
        $report += "$esc]7;$(([System.Uri]$path).AbsoluteUri)$bel"
        $userHome = $env:USERPROFILE
        $title = if ($userHome -and $path.StartsWith($userHome, [System.StringComparison]::OrdinalIgnoreCase)) { '~' + $path.Substring($userHome.Length) } else { $path }
        $report += "$esc]2;$title$bel"
    }
    $original = if ($global:__ProgramaPrompt) { & $global:__ProgramaPrompt } else { "PS $location$('>' * ($nestedPromptLevel + 1)) " }
    "$report$original$esc]133;B$bel"
}

# Claude Code started in a Programa terminal gets what the macOS `claude` wrapper gives it: the
# programa MCP server (docs/mcp-server.md) with --mcp-config=<file>, and hooks that report its
# session to Programa with --settings=<file> (equals forms, so a flag never swallows a prompt).
# Nothing is written to your Claude config. Your own --mcp-config, --strict-mcp-config or
# --settings, and the mcp/config subcommands, pass through as is.
if ($env:PROGRAMA_MCP_CONFIG -or $env:PROGRAMA_CLAUDE_SETTINGS) {
    function global:claude {
        $real = Get-Command claude -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $real) { Write-Error 'claude is not installed'; return }
        $added = @()
        if (-not ($args.Count -gt 0 -and "$($args[0])" -in @('mcp', 'config', 'api-key', 'rc', 'remote-control'))) {
            if ($env:PROGRAMA_MCP_CONFIG -and (Test-Path -LiteralPath $env:PROGRAMA_MCP_CONFIG) -and -not ($args | Where-Object { "$_" -match '^--(strict-)?mcp-config(=|$)' })) {
                $added += "--mcp-config=$env:PROGRAMA_MCP_CONFIG"
            }
            if ($env:PROGRAMA_CLAUDE_SETTINGS -and (Test-Path -LiteralPath $env:PROGRAMA_CLAUDE_SETTINGS) -and -not ($args | Where-Object { "$_" -match '^--settings(=|$)' })) {
                $added += "--settings=$env:PROGRAMA_CLAUDE_SETTINGS"
            }
        }
        & $real.Source @added @args
    }
}
