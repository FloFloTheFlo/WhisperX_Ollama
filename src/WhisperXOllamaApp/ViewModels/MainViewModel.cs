using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using WhisperXOllamaApp.Models;
using WhisperXOllamaApp.Services;
using WhisperXOllamaApp.Utilities;

namespace WhisperXOllamaApp.ViewModels;

public partial class MainViewModel : ObservableObject
{
    private readonly WhisperXService _whisperXService;
    private readonly OllamaService _ollamaService;
    private readonly PromptPresetStorage _presetStorage;
    private CancellationTokenSource? _processingCts;

    [ObservableProperty]
    private string _audioFilePath = string.Empty;

    [ObservableProperty]
    private ObservableCollection<string> _availableModels = new();

    [ObservableProperty]
    private string? _selectedModel;

    [ObservableProperty]
    private string _promptText = DefaultPrompt;

    [ObservableProperty]
    private ObservableCollection<PromptPreset> _promptPresets = new();

    [ObservableProperty]
    private PromptPreset? _selectedPreset;

    [ObservableProperty]
    private string _presetName = string.Empty;

    [ObservableProperty]
    private ObservableCollection<TranscriptChunk> _transcriptChunks = new();

    [ObservableProperty]
    private string _summaryText = string.Empty;

    [ObservableProperty]
    private string _transcriptionStatus = "Waiting for input.";

    [ObservableProperty]
    private bool _isProcessing;

    [ObservableProperty]
    private int _chunkSize = 1200;

    public IRelayCommand BrowseAudioCommand { get; }
    public IAsyncRelayCommand RefreshModelsCommand { get; }
    public IAsyncRelayCommand GenerateSummaryCommand { get; }
    public IAsyncRelayCommand SavePresetCommand { get; }
    public IRelayCommand LoadPresetCommand { get; }
    public IRelayCommand DeletePresetCommand { get; }

    private static string DefaultPrompt => """You are an expert meeting summarizer.\n""" +
        """Use the transcript chunk below to update the ongoing summary of the meeting.\n""" +
        """Current summary so far (may be empty):\n{{previous_summary}}\n\n""" +
        """Transcript chunk:\n{{chunk}}\n\n""" +
        """Provide an updated concise summary that: \n""" +
        """- Lists key decisions\n""" +
        """- Highlights action items with owners and due dates if present\n""" +
        """- Captures open questions\n\n""" +
        """Return only the updated summary text.""";

    public MainViewModel()
        : this(new WhisperXService(), new OllamaService(), new PromptPresetStorage())
    {
    }

    public MainViewModel(WhisperXService whisperXService, OllamaService ollamaService, PromptPresetStorage presetStorage)
    {
        _whisperXService = whisperXService;
        _ollamaService = ollamaService;
        _presetStorage = presetStorage;

        BrowseAudioCommand = new RelayCommand(BrowseAudioFile);
        RefreshModelsCommand = new AsyncRelayCommand(RefreshModelsAsync, () => !IsProcessing);
        GenerateSummaryCommand = new AsyncRelayCommand(GenerateSummaryAsync, () => !IsProcessing);
        SavePresetCommand = new AsyncRelayCommand(SavePresetAsync, () => !IsProcessing);
        LoadPresetCommand = new RelayCommand(LoadSelectedPreset, () => SelectedPreset is not null);
        DeletePresetCommand = new RelayCommand(DeleteSelectedPreset, () => SelectedPreset is not null && !IsProcessing);
    }

    partial void OnIsProcessingChanged(bool value)
    {
        RefreshModelsCommand.NotifyCanExecuteChanged();
        GenerateSummaryCommand.NotifyCanExecuteChanged();
        SavePresetCommand.NotifyCanExecuteChanged();
        (DeletePresetCommand as RelayCommand)?.NotifyCanExecuteChanged();
    }

    partial void OnSelectedPresetChanged(PromptPreset? value)
    {
        (LoadPresetCommand as RelayCommand)?.NotifyCanExecuteChanged();
        (DeletePresetCommand as RelayCommand)?.NotifyCanExecuteChanged();
    }

    partial void OnChunkSizeChanged(int value)
    {
        if (value <= 0)
        {
            ChunkSize = 1;
        }
    }

    public async void InitializeAsync()
    {
        try
        {
            await LoadPresetsAsync();
            await RefreshModelsAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Failed to initialize: {ex.Message}", "Initialization Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void BrowseAudioFile()
    {
        var dialog = new OpenFileDialog
        {
            Filter = "Audio Files|*.wav;*.mp3;*.m4a;*.flac;*.ogg|All Files|*.*"
        };

        if (dialog.ShowDialog() == true)
        {
            AudioFilePath = dialog.FileName;
        }
    }

    private async Task RefreshModelsAsync()
    {
        try
        {
            IsProcessing = true;
            TranscriptionStatus = "Loading Ollama models...";
            var models = await _ollamaService.ListModelsAsync(CancellationToken.None);
            Application.Current.Dispatcher.Invoke(() =>
            {
                AvailableModels = new ObservableCollection<string>(models);
                if (!models.Contains(SelectedModel))
                {
                    SelectedModel = models.FirstOrDefault();
                }
            });
            TranscriptionStatus = models.Count > 0 ? "Models loaded." : "No models available.";
        }
        catch (Exception ex)
        {
            TranscriptionStatus = $"Failed to load models: {ex.Message}";
        }
        finally
        {
            IsProcessing = false;
        }
    }

    private async Task GenerateSummaryAsync()
    {
        if (string.IsNullOrWhiteSpace(AudioFilePath) || !File.Exists(AudioFilePath))
        {
            MessageBox.Show("Please select a valid audio file.", "Missing Audio", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (string.IsNullOrWhiteSpace(SelectedModel))
        {
            MessageBox.Show("Please choose an Ollama model.", "Missing Model", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        _processingCts?.Cancel();
        _processingCts = new CancellationTokenSource();
        var cancellationToken = _processingCts.Token;

        try
        {
            IsProcessing = true;
            TranscriptionStatus = "Running WhisperX transcription...";
            var transcription = await _whisperXService.TranscribeAsync(AudioFilePath, cancellationToken);
            var chunks = TranscriptChunker.ChunkByWordCount(transcription.Segments, ChunkSize);
            Application.Current.Dispatcher.Invoke(() =>
            {
                TranscriptChunks = new ObservableCollection<TranscriptChunk>(chunks);
            });
            TranscriptionStatus = $"Transcription completed with {chunks.Count} chunk(s).";

            var previousSummary = string.Empty;
            var chunkIndex = 1;
            foreach (var chunk in chunks)
            {
                cancellationToken.ThrowIfCancellationRequested();
                TranscriptionStatus = $"Summarizing chunk {chunkIndex} of {chunks.Count}...";
                var prompt = BuildPromptForChunk(chunk.Content, previousSummary);
                var response = await _ollamaService.GenerateResponseAsync(SelectedModel!, prompt, cancellationToken);
                previousSummary = response.Trim();
                chunkIndex++;
            }

            SummaryText = previousSummary;
            TranscriptionStatus = "Summary generation complete.";
        }
        catch (OperationCanceledException)
        {
            TranscriptionStatus = "Processing cancelled.";
        }
        catch (Exception ex)
        {
            TranscriptionStatus = $"Failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Processing Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsProcessing = false;
        }
    }

    private string BuildPromptForChunk(string chunkContent, string previousSummary)
    {
        return PromptText
            .Replace("{{chunk}}", chunkContent)
            .Replace("{{previous_summary}}", string.IsNullOrWhiteSpace(previousSummary) ? "(none)" : previousSummary);
    }

    private async Task SavePresetAsync()
    {
        if (string.IsNullOrWhiteSpace(PresetName))
        {
            MessageBox.Show("Enter a name for the preset.", "Preset Name Required", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var existing = PromptPresets.FirstOrDefault(p => string.Equals(p.Name, PresetName, StringComparison.OrdinalIgnoreCase));
        if (existing is null)
        {
            existing = new PromptPreset { Name = PresetName };
            PromptPresets.Add(existing);
        }

        existing.Prompt = PromptText;
        await _presetStorage.SaveAsync(PromptPresets);
        MessageBox.Show($"Preset '{PresetName}' saved.", "Preset Saved", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private async Task LoadPresetsAsync()
    {
        try
        {
            var presets = await _presetStorage.LoadAsync();
            Application.Current.Dispatcher.Invoke(() =>
            {
                PromptPresets = new ObservableCollection<PromptPreset>(presets);
            });
        }
        catch (Exception ex)
        {
            TranscriptionStatus = $"Failed to load presets: {ex.Message}";
        }
    }

    private void LoadSelectedPreset()
    {
        if (SelectedPreset is null)
        {
            return;
        }

        PromptText = SelectedPreset.Prompt;
        PresetName = SelectedPreset.Name;
    }

    private async void DeleteSelectedPreset()
    {
        if (SelectedPreset is null)
        {
            return;
        }

        if (MessageBox.Show($"Delete preset '{SelectedPreset.Name}'?", "Delete Preset", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
        {
            PromptPresets.Remove(SelectedPreset);
            await _presetStorage.SaveAsync(PromptPresets);
            SelectedPreset = null;
        }
    }
}
