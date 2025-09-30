using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using WhisperXOllamaApp.Models;

namespace WhisperXOllamaApp.Services;

public class WhisperXService
{
    private readonly WhisperXOptions _options;

    public WhisperXService()
        : this(new WhisperXOptions())
    {
    }

    public WhisperXService(WhisperXOptions options)
    {
        _options = options;
    }

    public async Task<WhisperXResult> TranscribeAsync(string audioPath, CancellationToken cancellationToken)
    {
        if (!File.Exists(audioPath))
        {
            throw new FileNotFoundException("Audio file not found", audioPath);
        }

        var outputDir = PrepareOutputDirectory();
        var psi = new ProcessStartInfo
        {
            FileName = _options.ExecutablePath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        psi.ArgumentList.Add(audioPath);
        psi.ArgumentList.Add("--model");
        psi.ArgumentList.Add(_options.Model);
        psi.ArgumentList.Add("--output_dir");
        psi.ArgumentList.Add(outputDir);
        psi.ArgumentList.Add("--output_format");
        psi.ArgumentList.Add("json");
        psi.ArgumentList.Add("--compute_type");
        psi.ArgumentList.Add(_options.ComputeType);

        if (_options.EnableDiarization)
        {
            psi.ArgumentList.Add("--diarize");
        }

        if (!string.IsNullOrWhiteSpace(_options.Language))
        {
            psi.ArgumentList.Add("--language");
            psi.ArgumentList.Add(_options.Language!);
        }

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start whisperx process");

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

        await WaitForExitAsync(process, cancellationToken).ConfigureAwait(false);

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"WhisperX exited with code {process.ExitCode}: {stderr}\n{stdout}");
        }

        var resultFile = Directory.EnumerateFiles(outputDir, "*.json").FirstOrDefault();
        if (resultFile is null)
        {
            throw new FileNotFoundException("WhisperX did not produce a JSON transcription file", outputDir);
        }

        await using var stream = File.OpenRead(resultFile);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
        var segments = ParseSegments(document.RootElement);
        CleanupOutputDirectory(outputDir);
        return new WhisperXResult(segments);
    }

    private static async Task WaitForExitAsync(Process process, CancellationToken cancellationToken)
    {
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryTerminateProcessTree(process);
            await process.WaitForExitAsync().ConfigureAwait(false);
            throw;
        }
    }

    private static void TryTerminateProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process has already exited.
        }
        catch (NotSupportedException)
        {
            // Terminating the entire process tree is not supported on this platform.
        }
        catch (Win32Exception)
        {
            // Access denied or other OS level error. Nothing further to do here.
        }
    }

    private static IReadOnlyList<TranscriptionSegment> ParseSegments(JsonElement root)
    {
        if (root.TryGetProperty("segments", out var segmentsElement) && segmentsElement.ValueKind == JsonValueKind.Array)
        {
            var segments = new List<TranscriptionSegment>();
            foreach (var element in segmentsElement.EnumerateArray())
            {
                var speaker = element.TryGetProperty("speaker", out var speakerElement) ? speakerElement.GetString() ?? "Speaker" : "Speaker";
                var text = element.TryGetProperty("text", out var textElement) ? textElement.GetString() ?? string.Empty : string.Empty;
                var start = element.TryGetProperty("start", out var startElement) ? startElement.GetDouble() : 0d;
                var end = element.TryGetProperty("end", out var endElement) ? endElement.GetDouble() : start;

                segments.Add(new TranscriptionSegment(speaker, start, end, text.Trim()));
            }

            return segments;
        }

        throw new InvalidOperationException("WhisperX JSON output does not contain a 'segments' array.");
    }

    private string PrepareOutputDirectory()
    {
        if (!string.IsNullOrWhiteSpace(_options.OutputDirectory))
        {
            Directory.CreateDirectory(_options.OutputDirectory);
            return _options.OutputDirectory;
        }

        var tempDir = Path.Combine(Path.GetTempPath(), "WhisperXOllamaApp", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        return tempDir;
    }

    private static void CleanupOutputDirectory(string directory)
    {
        try
        {
            if (Directory.Exists(directory) && directory.Contains("WhisperXOllamaApp", StringComparison.OrdinalIgnoreCase))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
        catch
        {
            // Ignore cleanup failures.
        }
    }
}
