# Requires -Version 5.1
[CmdletBinding()]
param()

# ==== LOAD WPF ====
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ==== ENCODING FIXES (critical for accents) ====
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom   = New-Object System.Text.UTF8Encoding($true)
try {
    [Console]::OutputEncoding = $Utf8NoBom
    [Console]::InputEncoding  = $Utf8NoBom
} catch {}
$OutputEncoding = $Utf8NoBom

# ==== GLOBALS ====
$condaPath    = "D:\Users\flore\miniconda3\condabin\conda.bat"
$whisperxEnv  = "whisperx"
$script:cleanTranscript = ""
$script:detectedLang    = "the language used in the meeting"

# Default prompt template (placeholders are replaced at runtime)
$defaultPrompt = @"
You are an expert meeting summarizer creating notes for a busy audience who did not attend the meeting.

From the transcript below, produce a concise, well‑structured summary that:
- Omits small talk, filler words, and irrelevant tangents.
- Groups related points by topic rather than strict chronology.
- Prioritizes decisions, blockers, and deadlines at the top.
- Highlights key terms and names in bold for quick scanning.
- Uses bullet points for clarity and short paragraphs for readability.
- Replaces generic speaker labels (e.g., "[SPEAKER_00]") with the most likely name or role inferred from context so that generic speaker labels are never shown.
- Writes the summary in {LANGUAGE}; do not translate to any other language.
- Preserves speaker labels only when they add clarity to the point.
- Limits the total length to around 300–400 words.
- Ends with a short “Next Steps” section summarizing upcoming actions.

Format the output with these sections:
1. Attendees – list all speakers by inferred name or role (fallback to labels if uncertain).
2. Agenda – bullet points of topics covered.
3. Key Decisions & Deadlines – list in order of importance.
4. Discussion Points – concise summaries grouped by topic.
5. Action Items per Speaker – bullet points of tasks assigned, grouped by inferred speaker name/role.
6. Next Steps – brief overview of what happens after the meeting.

Transcript:
{TRANSCRIPT}
"@

# ==== XAML (neutral bright theme) ====
$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WhisperX → Ollama Summarizer" Height="820" Width="900"
        Background="#FAFAFA" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12">
    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#4DB6AC"/>
        <Style TargetType="Button">
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Margin" Value="0,4,0,8"/>
            <Setter Property="BorderBrush" Value="#DDDDDD"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="White"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Margin" Value="0,0,8,0"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Margin" Value="8,0,0,0"/>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Height" Value="6"/>
            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Background" Value="#EAEAEA"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Padding" Value="10,6"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#333333"/>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Top row: file path + browse + diarization -->
        <DockPanel Grid.Row="0" LastChildFill="True">
            <Label Content="Audio:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Name="AudioPathText" Text="No audio file selected" VerticalAlignment="Center" Foreground="#666666" TextTrimming="CharacterEllipsis"/>
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
                <CheckBox Name="DiarizeCheckbox" Content="Diarization" IsChecked="True" VerticalAlignment="Center"/>
                <Button Name="BrowseButton" Content="Browse Audio" />
            </StackPanel>
        </DockPanel>

        <!-- Second row: model + status + language -->
        <DockPanel Grid.Row="1" Margin="0,8,0,0">
            <StackPanel Orientation="Horizontal">
                <Label Content="Model:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <ComboBox Name="ModelDropdown" Width="220"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
                <Label Name="LangLabel" Content="Language: ?" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <Label Name="StatusLabel" Content="Status: Idle" VerticalAlignment="Center"/>
            </StackPanel>
        </DockPanel>

        <!-- Third row: progress -->
        <ProgressBar Name="MainProgress" Grid.Row="2" Margin="0,8,0,8" IsIndeterminate="False" Visibility="Collapsed"/>

        <!-- Tabs -->
        <TabControl Name="MainTabs" Grid.Row="3" Margin="0,4,0,8">
            <TabItem Header="Log">
                <Grid Background="White">
                    <TextBox Name="OutputLog" Margin="8" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" IsReadOnly="True" AcceptsReturn="True"/>
                </Grid>
            </TabItem>
            <TabItem Header="Summary Preview">
                <Grid Background="White">
                    <TextBox Name="PreviewBox" Margin="8" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" IsReadOnly="True" AcceptsReturn="True"/>
                </Grid>
            </TabItem>
            <TabItem Header="Prompt Editor">
                <Grid Background="White">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBox Name="PromptEditor" Grid.Row="0" Margin="8" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
                    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Left" Margin="8">
                        <Button Name="ResetPromptButton" Content="Reset Prompt" />
                    </StackPanel>
                </Grid>
            </TabItem>
            <TabItem Header="Final Summary">
                <Grid Background="White">
                    <TextBox Name="FinalBox" Margin="8" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" IsReadOnly="True" AcceptsReturn="True"/>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Bottom row: unload + run -->
        <DockPanel Grid.Row="4">
            <CheckBox Name="UnloadCheckbox" Content="Unload Ollama model after run (free VRAM)" IsChecked="True" VerticalAlignment="Center"/>
            <Button Name="RunButton" Content="Run WhisperX + Ollama" DockPanel.Dock="Right"/>
        </DockPanel>
    </Grid>
</Window>
"@

# ==== PARSE XAML ====
$reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# ==== GET CONTROLS ====
$AudioPathText     = $Window.FindName('AudioPathText')
$BrowseButton      = $Window.FindName('BrowseButton')
$DiarizeCheckbox   = $Window.FindName('DiarizeCheckbox')
$ModelDropdown     = $Window.FindName('ModelDropdown')
$StatusLabel       = $Window.FindName('StatusLabel')
$LangLabel         = $Window.FindName('LangLabel')
$MainProgress      = $Window.FindName('MainProgress')
$MainTabs          = $Window.FindName('MainTabs')
$OutputLog         = $Window.FindName('OutputLog')
$PreviewBox        = $Window.FindName('PreviewBox')
$PromptEditor      = $Window.FindName('PromptEditor')
$ResetPromptButton = $Window.FindName('ResetPromptButton')
$FinalBox          = $Window.FindName('FinalBox')
$UnloadCheckbox    = $Window.FindName('UnloadCheckbox')
$RunButton         = $Window.FindName('RunButton')

# ==== INIT PROMPT ====
$PromptEditor.Text = $defaultPrompt

# ==== HELPERS ====
function Append-Log($text) {
    $OutputLog.AppendText("$text`r`n")
    $OutputLog.ScrollToEnd()
}

function Clean-Transcript($raw) {
    $clean = $raw -replace '\[\d{2}:\d{2}:\d{2}\.\d+\]',''
    $clean = $clean -replace '\b\d{2}:\d{2}:\d{2}\b',''
    $clean = $clean -replace '(?i)\[inaudible\]',''
    $clean = ($clean -split "`r?`n") -join " "
    return ($clean -replace '\s+',' ')
}

function Detect-LanguageFromLogs($stdoutText, $stderrText) {
    $combined = ($stdoutText + "`n" + $stderrText)
    if ($combined -match 'Detected language:\s*([a-z]{2})(?:\s*\(([0-9.]+)\))?') {
        $result = @{
            code = $matches[1]
            confidence = $null
        }
        if ($matches.Count -ge 3 -and $matches[2]) {
            $result.confidence = $matches[2]
        }
        return $result
    }
    return $null
}

function Get-RunningOllamaModels {
    try {
        $lines = & ollama ps
        if (-not $lines) { return @() }
        $models = @()
        foreach ($line in $lines) {
            if ($line -match '^\s*NAME\b' -or [string]::IsNullOrWhiteSpace($line)) { continue }
            $name = ($line -split '\s+')[0]
            if ($name -and -not ($models -contains $name)) {
                $models += $name
            }
        }
        return $models
    } catch {
        return @()
    }
}

function Stop-OllamaModels([string[]]$models) {
    foreach ($m in $models) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        try {
            Append-Log "Stopping Ollama model: $m"
            & ollama stop $m | Out-Null
        } catch {
            Append-Log "Could not stop model '$m': $($_.Exception.Message)"
        }
    }
}

# ==== CORE WORKFLOW ====
function Run-WhisperX-And-Ollama {
    try {
        if (-not $AudioPathText.Text -or $AudioPathText.Text -eq "No audio file selected") {
            [System.Windows.MessageBox]::Show("Please select an audio file first.","Missing audio","OK","Warning") | Out-Null
            return
        }
        if (-not $ModelDropdown.SelectedItem) {
            [System.Windows.MessageBox]::Show("Please select an Ollama model.","Missing model","OK","Warning") | Out-Null
            return
        }

        $audioPath     = $AudioPathText.Text
        $audioBaseName = [System.IO.Path]::GetFileNameWithoutExtension($audioPath)
        $audioFolder   = [System.IO.Path]::GetDirectoryName($audioPath)
        $outputDir     = Join-Path $audioFolder "whisperx_results"
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

        $StatusLabel.Content = "Status: Running WhisperX..."
        $MainProgress.IsIndeterminate = $true
        $MainProgress.Visibility = "Visible"
        Append-Log "=== Running WhisperX ==="

        $diarizeFlag = if ($DiarizeCheckbox.IsChecked) { "--diarize" } else { "" }
        $whisperCmd = "call `"$condaPath`" activate $whisperxEnv && whisperx `"$audioPath`" --model large-v2 $diarizeFlag --output_dir `"$outputDir`" --compute_type float16"
        Append-Log "Command: $whisperCmd"

        $stdoutFile = Join-Path $audioFolder "whisperx_out.log"
        $stderrFile = Join-Path $audioFolder "whisperx_err.log"

        Start-Process -FilePath "cmd.exe" -ArgumentList "/c $whisperCmd" -NoNewWindow -Wait `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

        Append-Log "=== WhisperX finished ==="

        $stdoutText = ""
        if (Test-Path $stdoutFile) { $stdoutText = Get-Content $stdoutFile -Raw -Encoding UTF8 }
        $stderrText = ""
        if (Test-Path $stderrFile) { $stderrText = Get-Content $stderrFile -Raw -Encoding UTF8 }

        $langInfo = Detect-LanguageFromLogs $stdoutText $stderrText
        if ($langInfo -ne $null -and $langInfo.code) {
            $script:detectedLang = $langInfo.code
            if ($langInfo.confidence) {
                $LangLabel.Content = "Language: $($langInfo.code) ($($langInfo.confidence))"
            } else {
                $LangLabel.Content = "Language: $($langInfo.code)"
            }
            Append-Log "Detected language: $($LangLabel.Content)"
        } else {
            $script:detectedLang = "the language used in the meeting"
            $LangLabel.Content = "Language: ?"
            Append-Log "Could not detect language; using meeting language."
        }

        $transcriptFile = Get-ChildItem $outputDir -Filter *.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $transcriptFile) {
            Append-Log "No transcript file found."
            $StatusLabel.Content = "Status: Idle"
            $MainProgress.Visibility = "Collapsed"
            return
        }

        $rawTranscript = Get-Content $transcriptFile.FullName -Raw -Encoding UTF8
        $script:cleanTranscript = Clean-Transcript $rawTranscript
        Append-Log "Transcript loaded and cleaned."

        # === Run Ollama ===
        $StatusLabel.Content = "Status: Running Ollama..."
        Append-Log "=== Running Ollama ==="

        $promptText = $PromptEditor.Text
        $promptText = $promptText.Replace("{LANGUAGE}", $script:detectedLang)
        $promptText = $promptText.Replace("{TRANSCRIPT}", $script:cleanTranscript)

        $summaryPath   = Join-Path $audioFolder "$audioBaseName.summary.md"
        $selectedModel = [string]$ModelDropdown.SelectedItem

        $ollamaOutput = & ollama run $selectedModel $promptText
        $finalSummary = ($ollamaOutput -join "`r`n")

        [System.IO.File]::WriteAllText($summaryPath, $finalSummary, $Utf8Bom)

        $PreviewBox.Text = $finalSummary
        $FinalBox.Text   = $finalSummary
        $MainTabs.SelectedIndex = 3  # Final Summary tab

        Append-Log "=== Ollama finished ==="
        Append-Log "Summary saved to: $summaryPath"

        if ($UnloadCheckbox.IsChecked -and $selectedModel) {
            Append-Log "Auto-unloading Ollama model: $selectedModel"
            try {
                & ollama stop $selectedModel | Out-Null
                Append-Log "Model unloaded."
            } catch {
                Append-Log "Could not unload model '$selectedModel': $($_.Exception.Message)"
            }
        }

        $StatusLabel.Content = "Status: Done"
        $MainProgress.IsIndeterminate = $false
        $MainProgress.Visibility = "Collapsed"
    }
    catch {
        $MainProgress.IsIndeterminate = $false
        $MainProgress.Visibility = "Collapsed"
        $StatusLabel.Content = "Status: Error"
        Append-Log "Error: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("An error occurred: $($_.Exception.Message)","Error","OK","Error") | Out-Null
    }
}

# ==== EVENTS ====
$BrowseButton.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = "Audio files (*.mp3;*.wav;*.m4a)|*.mp3;*.wav;*.m4a|All files (*.*)|*.*"
    if ($ofd.ShowDialog()) {
        $AudioPathText.Text = $ofd.FileName
        $StatusLabel.Content  = "Status: Ready"
        $LangLabel.Content    = "Language: ?"
        $PreviewBox.Text      = ""
        $FinalBox.Text        = ""
        Append-Log "Selected: $($ofd.FileName)"
    }
})

$ResetPromptButton.Add_Click({
    $PromptEditor.Text = $defaultPrompt
    Append-Log "Prompt reset to default."
})

$RunButton.Add_Click({
    Run-WhisperX-And-Ollama
})

$Window.Add_Closing({
    Append-Log "Closing… attempting VRAM cleanup (stopping running Ollama models)."
    $running = Get-RunningOllamaModels
    if ($running.Count -gt 0) {
        Stop-OllamaModels -models $running
    } else {
        Append-Log "No running Ollama models detected."
    }
})

# ==== POPULATE MODELS (default to gemma3:12b if present) ====
try {
    $models = & ollama list | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -ne "" }
    foreach ($m in $models) { [void]$ModelDropdown.Items.Add($m) }
    if ($ModelDropdown.Items.Count -gt 0) {
        if ($models -contains 'gemma3:12b') { $ModelDropdown.SelectedItem = 'gemma3:12b' }
        else { $ModelDropdown.SelectedIndex = 0 }
    }
    Append-Log "Ollama models loaded."
} catch {
    Append-Log "Could not fetch Ollama models. Ensure 'ollama' is installed and in PATH."
}

# ==== SHOW WINDOW ====
$Window.Topmost = $true
[void]$Window.ShowDialog()