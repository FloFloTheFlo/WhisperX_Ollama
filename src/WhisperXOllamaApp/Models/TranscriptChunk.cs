using System;

namespace WhisperXOllamaApp.Models;

public class TranscriptChunk
{
    public string Header { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public TimeSpan Start { get; set; }
    public TimeSpan End { get; set; }
}
