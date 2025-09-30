namespace WhisperXOllamaApp.Models;

public class PromptPreset
{
    public string Name { get; set; } = string.Empty;
    public string Prompt { get; set; } = string.Empty;

    public override string ToString() => Name;
}
