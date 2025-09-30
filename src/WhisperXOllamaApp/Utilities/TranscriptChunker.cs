using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using WhisperXOllamaApp.Models;

namespace WhisperXOllamaApp.Utilities;

public static class TranscriptChunker
{
    public static IReadOnlyList<TranscriptChunk> ChunkByWordCount(IEnumerable<TranscriptionSegment> segments, int maxWords)
    {
        if (maxWords <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxWords), "Chunk size must be greater than zero.");
        }

        var chunkList = new List<TranscriptChunk>();
        var buffer = new StringBuilder();
        var wordCount = 0;
        TranscriptionSegment? firstSegment = null;
        TranscriptionSegment? lastSegment = null;

        void CommitChunk()
        {
            if (buffer.Length == 0 || firstSegment is null || lastSegment is null)
            {
                return;
            }

            var header = $"{FormatTimestamp(firstSegment.Start)} - {FormatTimestamp(lastSegment.End)} ({firstSegment.Speaker})";
            chunkList.Add(new TranscriptChunk
            {
                Header = header,
                Content = buffer.ToString().Trim(),
                Start = TimeSpan.FromSeconds(firstSegment.Start),
                End = TimeSpan.FromSeconds(lastSegment.End),
            });

            buffer.Clear();
            wordCount = 0;
            firstSegment = null;
            lastSegment = null;
        }

        foreach (var segment in segments)
        {
            var words = segment.Text.Split(new[] { ' ', '\n', '\r', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (wordCount + words.Length > maxWords && buffer.Length > 0)
            {
                CommitChunk();
            }

            if (firstSegment is null)
            {
                firstSegment = segment;
            }

            lastSegment = segment;
            if (buffer.Length > 0)
            {
                buffer.AppendLine();
            }

            buffer.Append($"[{FormatTimestamp(segment.Start)} - {FormatTimestamp(segment.End)}] {segment.Speaker}: {segment.Text.Trim()}");
            wordCount += words.Length;
        }

        CommitChunk();
        return chunkList;
    }

    private static string FormatTimestamp(double seconds)
    {
        var ts = TimeSpan.FromSeconds(seconds);
        return ts.ToString(ts.TotalHours >= 1 ? "hh\:mm\:ss" : "mm\:ss", CultureInfo.InvariantCulture);
    }
}
