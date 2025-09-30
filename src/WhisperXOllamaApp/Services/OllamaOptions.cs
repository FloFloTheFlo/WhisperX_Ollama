using System;

namespace WhisperXOllamaApp.Services;

public class OllamaOptions
{
    public string ExecutablePath { get; set; } = "ollama";
    public TimeSpan CommandTimeout { get; set; } = TimeSpan.FromMinutes(10);
}
