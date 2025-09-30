using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using WhisperXOllamaApp.Models;

namespace WhisperXOllamaApp.Services;

public class PromptPresetStorage
{
    private readonly string _filePath;
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public PromptPresetStorage()
        : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WhisperXOllamaApp", "prompt-presets.json"))
    {
    }

    public PromptPresetStorage(string filePath)
    {
        _filePath = filePath;
    }

    public async Task<IReadOnlyList<PromptPreset>> LoadAsync()
    {
        if (!File.Exists(_filePath))
        {
            return Array.Empty<PromptPreset>();
        }

        await using var stream = File.OpenRead(_filePath);
        var presets = await JsonSerializer.DeserializeAsync<List<PromptPreset>>(stream, SerializerOptions).ConfigureAwait(false);
        return presets ?? new List<PromptPreset>();
    }

    public async Task SaveAsync(IEnumerable<PromptPreset> presets)
    {
        var directory = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        await using var stream = File.Create(_filePath);
        await JsonSerializer.SerializeAsync(stream, presets, SerializerOptions).ConfigureAwait(false);
    }
}
