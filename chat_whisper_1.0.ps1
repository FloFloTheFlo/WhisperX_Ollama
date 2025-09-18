# chat_whisper_2.2.ps1
# WhisperX → Ollama (chunked) GUI — PowerShell 5.1 compatible
# Uses Start-Job for background work; robust polling with batched log flush to avoid WPF message floods.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------- Encoding ----------
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom; [Console]::InputEncoding = $Utf8NoBom } catch {}

# ---------- Script-level state ----------
$script:currentJob      = $null
$script:pollTimer       = $null
$script:jobLastCount    = 0
$script:__chunkSummaries = @{}

# Batched UI log buffer and flusher to avoid PostMessage quota issues
$script:__pendingLogSB  = New-Object System.Text.StringBuilder
$script:logFlushTimer   = $null

# ---------- UI-log helpers (batched) ----------
function Append-LogUI([string]$txt) {
    if ([string]::IsNullOrWhiteSpace($txt)) { return }
    $ts = (Get-Date).ToString("HH:mm:ss")
    try { [Console]::WriteLine("[$ts] $txt") } catch {}
    if ($OutputLog -ne $null) {
        [void]$script:__pendingLogSB.AppendFormat("[{0}] {1}`r`n", $ts, $txt)
    }
}
function Append-Log([string]$txt) {
    if ($OutputLog -ne $null) {
        try {
            if ($OutputLog.Dispatcher.CheckAccess()) { Append-LogUI $txt }
            else { $Window.Dispatcher.BeginInvoke([action]{ Append-LogUI $txt }) | Out-Null }
        } catch { try { Append-LogUI $txt } catch {} }
    } else { try { [Console]::WriteLine($txt) } catch {} }
}
function Flush-LogBuffer {
    if ($OutputLog -eq $null) { return }
    if ($script:__pendingLogSB.Length -le 0) { return }
    $OutputLog.AppendText($script:__pendingLogSB.ToString())
    [void]$script:__pendingLogSB.Clear()
    # Trim the log text if it grows too large (keep last 400k chars)
    try {
        $textLen = $OutputLog.Text.Length
        if ($textLen -gt 800000) {
            $OutputLog.Text = $OutputLog.Text.Substring($textLen - 400000)
        }
    } catch {}
    $OutputLog.ScrollToEnd()
}

# ---------- Tool resolution ----------
function Resolve-ExeFromPath($exeName) {
    if (-not $env:PATH) { return $null }
    foreach ($dir in $env:PATH.Split(';')) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir $exeName
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}
function Resolve-Tool { param([string[]]$Names)
    foreach ($n in $Names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) {
            if ($null -ne $c.Path) { return $c.Path }
            if ($null -ne $c.Source) { return $c.Source }
            if ($null -ne $c.Definition) { return $c.Definition }
        }
        $p = Resolve-ExeFromPath $n
        if ($p) { return $p }
    }
    if ($Names -contains 'ollama' -or $Names -contains 'ollama.exe') {
        $cands = @(
            "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
            "C:\Program Files\Ollama\ollama.exe",
            "C:\Program Files (x86)\Ollama\ollama.exe"
        )
        foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    }
    if ($Names -contains 'conda' -or $Names -contains 'conda.bat') {
        if ($env:CONDA_EXE -and (Test-Path $env:CONDA_EXE)) { return $env:CONDA_EXE }
        $cands = @(
            "$env:USERPROFILE\miniconda3\condabin\conda.bat",
            "$env:USERPROFILE\anaconda3\condabin\conda.bat",
            "$env:USERPROFILE\miniconda3\Scripts\conda.exe",
            "D:\Users\flore\miniconda3\condabin\conda.bat"
        )
        foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    }
    return $null
}

# ---------- Defaults ----------
$script:detectedLang = "English"
$whisperxEnv = "whisperx"
$chunkOverlap = 80
$defaultPrompt = @"
You are an expert meeting summarizer. Produce a concise, well-structured meeting summary containing attendees, agenda, key decisions & deadlines, discussion points, action items, and next steps.

Write in {LANGUAGE}. Keep it short and scannable.

Transcript:
{TRANSCRIPT}
"@

# ---------- XAML ----------
$Xaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='WhisperX → Ollama (chunked)' Height='760' Width='980' WindowStartupLocation='CenterScreen'
        Background='#FAFAFA' FontFamily='Segoe UI' FontSize='12'>
  <Grid Margin='12'>
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='*'/>
      <RowDefinition Height='Auto'/>
    </Grid.RowDefinitions>

    <StackPanel Orientation='Horizontal' Grid.Row='0' Margin='0,0,0,8'>
      <Label Content='Audio:' VerticalAlignment='Center'/>
      <TextBlock Name='AudioPathText' Text='No audio file selected' Width='480' TextTrimming='CharacterEllipsis' Foreground='#666'/>
      <Button Name='BrowseButton' Content='Browse Audio' Margin='8,0,0,0'/>
      <Button Name='RefreshModelsButton' Content='Refresh Models' Margin='8,0,0,0'/>
    </StackPanel>

    <StackPanel Orientation='Horizontal' Grid.Row='1' Margin='0,0,0,8'>
      <CheckBox Name='DiarizeCheckbox' Content='Diarize' IsChecked='True' VerticalAlignment='Center'/>
      <Label Content='Model:' VerticalAlignment='Center' Margin='12,0,0,0'/>
      <ComboBox Name='ModelDropdown' Width='260'/>
      <Label Content='Chunk size (words):' VerticalAlignment='Center' Margin='12,0,0,0'/>
      <TextBox Name='ChunkSizeBox' Width='80' Text='1000' Margin='8,0,0,0'/>
      <CheckBox Name='ReSummarizeCheckbox' Content='Re-summarize final' IsChecked='True' Margin='12,0,0,0'/>
      <CheckBox Name='UnloadCheckbox' Content='Unload Ollama model after run' IsChecked='True' Margin='12,0,0,0'/>
    </StackPanel>

    <StackPanel Orientation='Horizontal' Grid.Row='2' Margin='0,0,0,8'>
      <ProgressBar Name='MainProgress' Width='480' Height='14' Minimum='0' Maximum='1' Value='0'/>
      <Label Name='StatusLabel' Content='Status: Idle' Margin='12,0,0,0' VerticalAlignment='Center'/>
      <Label Name='LangLabel' Content='Language: ?' Margin='12,0,0,0' VerticalAlignment='Center'/>
    </StackPanel>

    <TabControl Name='MainTabs' Grid.Row='3'>
      <TabItem Header='Log'><TextBox Name='OutputLog' AcceptsReturn='True' TextWrapping='Wrap' VerticalScrollBarVisibility='Auto' IsReadOnly='True'/></TabItem>
      <TabItem Header='Transcript Preview'><TextBox Name='PreviewBox' AcceptsReturn='True' TextWrapping='Wrap' VerticalScrollBarVisibility='Auto' IsReadOnly='True'/></TabItem>
      <TabItem Header='Prompt Editor'>
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
          <TextBox Name='PromptEditor' Grid.Row='0' AcceptsReturn='True' TextWrapping='Wrap' VerticalScrollBarVisibility='Auto'/>
          <StackPanel Grid.Row='1' Orientation='Horizontal' Margin='8'>
            <Button Name='ResetPromptButton' Content='Reset Prompt'/>
            <Button Name='SavePromptButton' Content='Save Prompt' Margin='8,0,0,0'/>
          </StackPanel>
        </Grid>
      </TabItem>
      <TabItem Header='Final Summary'><TextBox Name='FinalBox' AcceptsReturn='True' TextWrapping='Wrap' VerticalScrollBarVisibility='Auto' IsReadOnly='True'/></TabItem>
    </TabControl>

    <StackPanel Grid.Row='4' Orientation='Horizontal' HorizontalAlignment='Right' Margin='0,8,0,0'>
      <Button Name='RunButton' Content='Run WhisperX + Ollama' Width='220'/>
      <Button Name='AbortButton' Content='Abort' Width='100' Margin='8,0,0,0'/>
    </StackPanel>
  </Grid>
</Window>
"@

# ---------- Load UI ----------
$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Controls
$AudioPathText        = $Window.FindName('AudioPathText')
$BrowseButton         = $Window.FindName('BrowseButton')
$RefreshModelsButton  = $Window.FindName('RefreshModelsButton')
$DiarizeCheckbox      = $Window.FindName('DiarizeCheckbox')
$ModelDropdown        = $Window.FindName('ModelDropdown')
$ChunkSizeBox         = $Window.FindName('ChunkSizeBox')
$ReSummarizeCheckbox  = $Window.FindName('ReSummarizeCheckbox')
$UnloadCheckbox       = $Window.FindName('UnloadCheckbox')
$MainProgress         = $Window.FindName('MainProgress')
$StatusLabel          = $Window.FindName('StatusLabel')
$LangLabel            = $Window.FindName('LangLabel')
$OutputLog            = $Window.FindName('OutputLog')
$PreviewBox           = $Window.FindName('PreviewBox')
$PromptEditor         = $Window.FindName('PromptEditor')
$ResetPromptButton    = $Window.FindName('ResetPromptButton')
$SavePromptButton     = $Window.FindName('SavePromptButton')
$FinalBox             = $Window.FindName('FinalBox')
$RunButton            = $Window.FindName('RunButton')
$AbortButton          = $Window.FindName('AbortButton')

$PromptEditor.Text = $defaultPrompt

# Start the periodic log flusher
$script:logFlushTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:logFlushTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:logFlushTimer.add_Tick({ try { Flush-LogBuffer } catch {} })
$script:logFlushTimer.Start()

# ---------- Resolve tools ----------
$global:ollamaExe = Resolve-Tool -Names @('ollama','ollama.exe')
$global:condaPath = Resolve-Tool -Names @('conda','conda.bat','conda.exe')

# ---------- Model refresh ----------
function Refresh-Models {
    try {
        if (-not $global:ollamaExe) { Append-Log "ollama not found; cannot refresh models."; return }
        Append-Log ("Using ollama at: {0}" -f $global:ollamaExe)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $global:ollamaExe
        $psi.Arguments = "list"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null

        $output = New-Object System.Text.StringBuilder
        while (-not $proc.HasExited) {
            while (-not $proc.StandardOutput.EndOfStream) { $ln = $proc.StandardOutput.ReadLine(); if ($ln) { $output.AppendLine($ln) | Out-Null } }
            while (-not $proc.StandardError.EndOfStream)  { $ln = $proc.StandardError.ReadLine();  if ($ln) { $output.AppendLine($ln) | Out-Null } }
            Start-Sleep -Milliseconds 120
        }
        while (-not $proc.StandardOutput.EndOfStream) { $ln=$proc.StandardOutput.ReadLine(); if ($ln) { $output.AppendLine($ln) | Out-Null } }
        while (-not $proc.StandardError.EndOfStream)  { $ln=$proc.StandardError.ReadLine();  if ($ln) { $output.AppendLine($ln) | Out-Null } }

        $raw = $output.ToString().Trim()
        if (-not $raw) { Append-Log "No output from 'ollama list'."; return }

        $names = @()
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($o in $parsed) {
                if ($o.name) { $names += $o.name; continue }
                if ($o.id)   { $names += $o.id; continue }
                if ($o.Name) { $names += $o.Name; continue }
            }
        } catch {
            $lines = $raw -split "`r?`n"
            foreach ($line in $lines) {
                if ($line -match '^\s*NAME\b' -or [string]::IsNullOrWhiteSpace($line)) { continue }
                $token = $line.Trim()
                if ($token -match 'no models found') { continue }
                $first = ($token -split '\s+')[0]
                if ($first) { $names += $first }
            }
        }

        $unique = $names | Where-Object { $_ } | Select-Object -Unique
        if ($unique.Count -eq 0) {
            Append-Log "No models parsed from 'ollama list'."
            return
        }

        $ModelDropdown.Dispatcher.Invoke([action]{
            $ModelDropdown.Items.Clear()
            foreach ($m in $unique) { [void]$ModelDropdown.Items.Add($m) }
            if ($ModelDropdown.Items.Count -gt 0) { $ModelDropdown.SelectedIndex = 0 }
        })
        Append-Log ("Loaded models: {0}" -f ($unique -join ', '))
    } catch { Append-Log ("Error refreshing models: {0}" -f $_.Exception.Message) }
}

# ---------- Background job: heavy work ----------
$backgroundScript = {
    param($audio, $model, $promptTemplate, $chunkSize, $resummarize, $diarize, $condaPath, $ollamaExe, $whisperxEnv, $chunkOverlap, $language)
    function WriteLog($s) { if ($s) { Write-Output ("[LOG]" + $s) } }
    function WriteErr($s) { if ($s) { Write-Output ("[ERR]" + $s) } }

    try {
        WriteLog "Job started."
        if (-not [System.IO.File]::Exists($audio)) { WriteErr "Audio not found. Aborting."; return }
        WriteLog ("Selected audio: {0}" -f $audio)

        $audioFolder = [System.IO.Path]::GetDirectoryName($audio)
        $outDir = [System.IO.Path]::Combine($audioFolder, "whisperx_results")
        if (-not [System.IO.Directory]::Exists($outDir)) { [System.IO.Directory]::CreateDirectory($outDir) | Out-Null }

        $diarFlag = ""; if ($diarize) { $diarFlag = "--diarize" }

        if ($condaPath -and $condaPath.ToLower().EndsWith(".bat")) {
            $wrapper = "cmd.exe"
            $args = "/c call `"$condaPath`" run -n $whisperxEnv whisperx `"$audio`" --model large-v2 $diarFlag --output_dir `"$outDir`" --compute_type float16"
        } else {
            $wrapper = $condaPath
            $args = "run -n $whisperxEnv whisperx `"$audio`" --model large-v2 $diarFlag --output_dir `"$outDir`" --compute_type float16"
        }

        WriteLog ("Starting WhisperX via: {0} {1}" -f $wrapper, $args)
        $psi = New-Object System.Diagnostics.ProcessStartInfo($wrapper, $args)
        $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
        $proc = New-Object System.Diagnostics.Process; $proc.StartInfo=$psi; $proc.Start() | Out-Null

        # stream minimal to avoid flooding
        $tick = 0
        while (-not $proc.HasExited) {
            $bat = New-Object System.Text.StringBuilder
            $err = New-Object System.Text.StringBuilder
            $lines = 0
            while (-not $proc.StandardOutput.EndOfStream -and $lines -lt 120) { $ln=$proc.StandardOutput.ReadLine(); if ($ln) { [void]$bat.AppendLine($ln); $lines++ } }
            $lines = 0
            while (-not $proc.StandardError.EndOfStream  -and $lines -lt 80)  { $ln=$proc.StandardError.ReadLine();  if ($ln) { [void]$err.AppendLine($ln);  $lines++ } }
            if ($bat.Length -gt 0) { WriteLog ($bat.ToString().TrimEnd()) }
            if ($err.Length -gt 0) { WriteErr ($err.ToString().TrimEnd()) }
            Start-Sleep -Milliseconds 200
            $tick++
        }
        # final drain
        $finalOut = $proc.StandardOutput.ReadToEnd()
        $finalErr = $proc.StandardError.ReadToEnd()
        if ($finalOut) { WriteLog $finalOut.TrimEnd() }
        if ($finalErr) { WriteErr $finalErr.TrimEnd() }
        WriteLog ("WhisperX exit code: {0}" -f $proc.ExitCode)

        # find latest transcript
        $found = $null
        if ([System.IO.Directory]::Exists($outDir)) {
            $all = [System.IO.Directory]::EnumerateFiles($outDir, '*', [System.IO.SearchOption]::AllDirectories)
            foreach ($f in $all) {
                $l = $f.ToLower()
                if ($l.EndsWith('.txt') -or $l.EndsWith('.json')) {
                    if ($found -eq $null) { $found = $f }
                    elseif ((Get-Item $f).LastWriteTime -gt (Get-Item $found).LastWriteTime) { $found = $f }
                }
            }
        }
        if (-not $found) { WriteErr "No transcript file produced by WhisperX. Aborting."; return }
        WriteLog ("Transcript file found: {0}" -f $found)
        Write-Output ("[TRANSCRIPT_FILE]" + $found)

        # read & clean
        $transcriptText = ""
        try { $transcriptText = [System.IO.File]::ReadAllText($found, [System.Text.Encoding]::UTF8) } catch { WriteErr ("Failed to read transcript: {0}" -f $_.Exception.Message); return }
        $clean = $transcriptText -replace '\[\d{2}:\d{2}:\d{2}\.\d+\]',''
        $clean = $clean -replace '\s+',' '
        if (-not $clean) { WriteErr "Transcript empty after cleaning."; return }

        # chunk
        $words = $clean -split '\s+' | Where-Object { $_ -ne "" }
        $chunks = New-Object System.Collections.Generic.List[string]
        $i = 0; $n = $words.Length
        while ($i -lt $n) {
            $end = [Math]::Min($n, $i + [int]$chunkSize)
            $slice = $words[$i..($end - 1)] -join ' '
            [void]$chunks.Add($slice)
            $i = $end - [int]$chunkOverlap
            if ($i -lt 0) { $i = 0 }
            if ($i -ge $n) { break }
        }
        $total = $chunks.Count
        WriteLog ("Split transcript into {0} chunk(s)." -f $total)

        # summarize chunks
        $chunkSummaries = New-Object System.Collections.Generic.List[string]
        $idx = 0
        foreach ($chunk in $chunks) {
            $idx++
            WriteLog ("Summarizing chunk {0}/{1}..." -f $idx, $total)
            $promptFilled = $promptTemplate.Replace("{TRANSCRIPT}", $chunk).Replace("{LANGUAGE}", $language)

            $psi2 = New-Object System.Diagnostics.ProcessStartInfo($ollamaExe, "run $model")
            $psi2.RedirectStandardInput=$true; $psi2.RedirectStandardOutput=$true; $psi2.RedirectStandardError=$true; $psi2.UseShellExecute=$false; $psi2.CreateNoWindow=$true
            $proc2 = New-Object System.Diagnostics.Process; $proc2.StartInfo=$psi2; $proc2.Start() | Out-Null
            try { $proc2.StandardInput.WriteLine($promptFilled); $proc2.StandardInput.Close() } catch {}

            $sbOut = New-Object System.Text.StringBuilder
            while (-not $proc2.HasExited) {
                $linesThis = 0
                while (-not $proc2.StandardOutput.EndOfStream -and $linesThis -lt 120) { $ln=$proc2.StandardOutput.ReadLine(); if ($ln) { [void]$sbOut.AppendLine($ln); $linesThis++ } }
                $errBatch = New-Object System.Text.StringBuilder
                $linesErr = 0
                while (-not $proc2.StandardError.EndOfStream  -and $linesErr -lt 80)  { $ln=$proc2.StandardError.ReadLine();  if ($ln) { [void]$errBatch.AppendLine($ln); $linesErr++ } }
                if ($errBatch.Length -gt 0) { WriteErr ("[OLLAMA-ERR] " + $errBatch.ToString().TrimEnd()) }
                Start-Sleep -Milliseconds 150
            }
            $tailOut = $proc2.StandardOutput.ReadToEnd()
            $tailErr = $proc2.StandardError.ReadToEnd()
            if ($tailOut) { [void]$sbOut.AppendLine($tailOut) }
            if ($tailErr) { WriteErr ("[OLLAMA-ERR] " + $tailErr.TrimEnd()) }

            $chunkSummary = $sbOut.ToString().Trim()
            if (-not $chunkSummary) { $chunkSummary = "[No output from Ollama]" } else { WriteLog ("Chunk {0} summarized (chars: {1})." -f $idx, $chunkSummary.Length) }
            [void]$chunkSummaries.Add($chunkSummary)

            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($chunkSummary))
            Write-Output ("[CHUNK_SUMMARY]" + $idx + "|" + $b64)
            Write-Output ("[CHUNK_PROGRESS]" + $idx + "|" + $total)
        }

        # final consolidation
        if ($resummarize -and $chunkSummaries.Count -gt 1) {
            WriteLog "Running final consolidation..."
            $combined = ($chunkSummaries -join "`r`n`r`n")
            $finalPrompt = "You are an expert summarizer. Consolidate the following chunk summaries into a single concise meeting summary (300-400 words). Keep language as {LANGUAGE}.

{TRANSCRIPT}
"
            $finalPrompt = $finalPrompt.Replace("{LANGUAGE}", $language).Replace("{TRANSCRIPT}", $combined)

            $psi3 = New-Object System.Diagnostics.ProcessStartInfo($ollamaExe, "run $model")
            $psi3.RedirectStandardInput=$true; $psi3.RedirectStandardOutput=$true; $psi3.RedirectStandardError=$true; $psi3.UseShellExecute=$false; $psi3.CreateNoWindow=$true
            $proc3 = New-Object System.Diagnostics.Process; $proc3.StartInfo=$psi3; $proc3.Start() | Out-Null
            try { $proc3.StandardInput.WriteLine($finalPrompt); $proc3.StandardInput.Close() } catch {}

            $sbF = New-Object System.Text.StringBuilder
            while (-not $proc3.HasExited) {
                $linesThis = 0
                while (-not $proc3.StandardOutput.EndOfStream -and $linesThis -lt 160) { $ln=$proc3.StandardOutput.ReadLine(); if ($ln) { [void]$sbF.AppendLine($ln); $linesThis++ } }
                $errBatch = New-Object System.Text.StringBuilder
                while (-not $proc3.StandardError.EndOfStream) { $ln=$proc3.StandardError.ReadLine(); if ($ln) { [void]$errBatch.AppendLine($ln) } }
                if ($errBatch.Length -gt 0) { WriteErr ("[OLLAMA-FINAL-ERR] " + $errBatch.ToString().TrimEnd()) }
                Start-Sleep -Milliseconds 150
            }
            $tailFOut = $proc3.StandardOutput.ReadToEnd()
            $tailFErr = $proc3.StandardError.ReadToEnd()
            if ($tailFOut) { [void]$sbF.AppendLine($tailFOut) }
            if ($tailFErr) { WriteErr ("[OLLAMA-FINAL-ERR] " + $tailFErr.TrimEnd()) }

            $finalSummary = $sbF.ToString().Trim()
            if (-not $finalSummary) { $finalSummary = ($chunkSummaries -join "`r`n`r`n") }

            $b64final = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($finalSummary))
            Write-Output ("[FINAL_SUMMARY]" + $b64final)
        } else {
            $combined = ($chunkSummaries -join "`r`n`r`n")
            $b64final = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($combined))
            Write-Output ("[FINAL_SUMMARY]" + $b64final)
        }

        WriteLog "Job completed."
    } catch {
        Write-Output ("[ERR]Job exception: {0}" -f $_.Exception.Message)
    }
}

# ---------- UI events ----------
$BrowseButton.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = "Audio files (*.mp3;*.wav;*.m4a;*.flac)|*.mp3;*.wav;*.m4a;*.flac|All files (*.*)|*.*"
    if ($ofd.ShowDialog() -eq $true) {
        $AudioPathText.Text = $ofd.FileName
        Append-Log ("Selected audio: {0}" -f $ofd.FileName)
    }
})
$RefreshModelsButton.Add_Click({ Refresh-Models })
$ResetPromptButton.Add
