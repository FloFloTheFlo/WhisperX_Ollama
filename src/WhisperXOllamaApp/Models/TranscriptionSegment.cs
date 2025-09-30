namespace WhisperXOllamaApp.Models;

public record TranscriptionSegment(
    string Speaker,
    double Start,
    double End,
    string Text);
