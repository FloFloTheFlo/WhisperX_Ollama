using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WhisperXOllamaApp.Services;

public class OllamaService
{
    private readonly OllamaOptions _options;

    public OllamaService()
        : this(new OllamaOptions())
    {
    }

    public OllamaService(OllamaOptions options)
    {
        _options = options;
    }

    public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken cancellationToken)
    {
        var psi = CreateProcessStartInfo();
        psi.ArgumentList.Add("list");
        psi.ArgumentList.Add("--json");

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start ollama process");

        using var cancellationRegistration = cancellationToken.Register(() => TryTerminateProcess(process));

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryTerminateProcess(process);
            throw;
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Ollama list failed with code {process.ExitCode}: {stderr}");
        }

        var models = new List<string>();
        using var reader = new StringReader(stdout);
        string? line;
        while ((line = await reader.ReadLineAsync()) is not null)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            using var document = JsonDocument.Parse(line);
            if (document.RootElement.TryGetProperty("name", out var nameElement))
            {
                var name = nameElement.GetString();
                if (!string.IsNullOrWhiteSpace(name))
                {
                    models.Add(name);
                }
            }
        }

        return models;
    }

    public async Task<string> GenerateResponseAsync(string model, string prompt, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            throw new ArgumentException("Model cannot be empty", nameof(model));
        }

        var psi = CreateProcessStartInfo();
        psi.ArgumentList.Add("run");
        psi.ArgumentList.Add(model);

        using var process = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start ollama process");

        await process.StandardInput.WriteAsync(prompt);
        await process.StandardInput.FlushAsync();
        process.StandardInput.Close();

        var outputBuilder = new StringBuilder();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(_options.CommandTimeout);

        using var cancellationRegistration = cts.Token.Register(() => TryTerminateProcess(process));

        while (await process.StandardOutput.ReadLineAsync() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            try
            {
                using var document = JsonDocument.Parse(line);
                if (document.RootElement.TryGetProperty("response", out var responseElement))
                {
                    outputBuilder.Append(responseElement.GetString());
                }
            }
            catch (JsonException)
            {
                outputBuilder.AppendLine(line);
            }
        }

        var stderr = await process.StandardError.ReadToEndAsync().ConfigureAwait(false);
        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryTerminateProcess(process);
            throw;
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Ollama run failed with code {process.ExitCode}: {stderr}");
        }

        return outputBuilder.ToString();
    }

    private ProcessStartInfo CreateProcessStartInfo()
    {
        return new ProcessStartInfo
        {
            FileName = _options.ExecutablePath,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
    }

    private static void TryTerminateProcess(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Ignore termination failures.
        }
    }
}
