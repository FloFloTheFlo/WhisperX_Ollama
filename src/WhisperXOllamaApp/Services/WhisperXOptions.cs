namespace WhisperXOllamaApp.Services;

public class WhisperXOptions
{
    public string ExecutablePath { get; set; } = "whisperx";
    public string Model { get; set; } = "large-v2";
    public string? Language { get; set; }
    public string ComputeType { get; set; } = "auto";
    public bool EnableDiarization { get; set; } = true;
    public string? OutputDirectory { get; set; }
}
