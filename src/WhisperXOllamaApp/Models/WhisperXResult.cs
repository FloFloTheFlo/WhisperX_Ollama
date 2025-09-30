using System.Collections.Generic;

namespace WhisperXOllamaApp.Models;

public class WhisperXResult
{
    public IReadOnlyList<TranscriptionSegment> Segments { get; }

    public WhisperXResult(IReadOnlyList<TranscriptionSegment> segments)
    {
        Segments = segments;
    }
}
