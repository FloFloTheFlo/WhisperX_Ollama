# WhisperX Ollama Meeting Summarizer

This repository now includes a Windows Presentation Foundation (WPF) application that orchestrates local [WhisperX](https://github.com/m-bain/whisperx) transcriptions with speaker diarization and summarises the results using your locally installed [Ollama](https://ollama.com/) models.

## Features

- Select any meeting audio file and run WhisperX with diarization to obtain a detailed transcript.
- Automatically chunk long transcripts so that the Ollama model receives manageable input sizes.
- Choose which Ollama model to run by querying the locally installed models list.
- Edit the summarisation prompt directly in the UI, save prompt presets, and re-use them later.
- Display diarised transcript chunks with timestamps and speaker labels alongside the generated summary.

## Project layout

```
WhisperXOllamaApp.sln        # Visual Studio solution
src/
  WhisperXOllamaApp/         # WPF application source
```

## Building

The project targets **.NET 8.0** with WPF (`net8.0-windows10.0.19041.0`). Open the solution in Visual Studio 2022 (17.8 or later) on Windows with the `.NET Desktop Development` workload installed, then build and run the application.

If you prefer the CLI:

```powershell
dotnet build WhisperXOllamaApp.sln
dotnet run --project src/WhisperXOllamaApp/WhisperXOllamaApp.csproj
```

> **Note:** the container used to author this change does not have the .NET SDK installed, so builds were not executed here.

## Runtime dependencies

- **WhisperX** must be installed and available on the system `PATH` (or adjust the executable path inside `WhisperXOptions`). The app launches WhisperX with `--diarize` and `--output_format json` to capture diarised transcripts.
- **Ollama** must be installed locally and the CLI must be reachable via `ollama` on the `PATH`. The app uses `ollama list --json` to discover models and pipes prompts into `ollama run <model>` for each transcript chunk.

Ensure both tools are installed and functioning from a regular terminal before using the GUI.

## Prompt placeholders

The default prompt – and any presets you save – can use the following placeholders:

- `{{chunk}}` – the diarised transcript chunk that will be summarised.
- `{{previous_summary}}` – the cumulative summary generated from prior chunks (or `(none)` for the first chunk).

These placeholders are replaced automatically before sending the prompt to Ollama, enabling iterative summarisation of long meetings without overwhelming the model.

## Preset storage

Prompt presets are stored as JSON under `%APPDATA%\WhisperXOllamaApp\prompt-presets.json`. You can manually back up or edit this file if required.
