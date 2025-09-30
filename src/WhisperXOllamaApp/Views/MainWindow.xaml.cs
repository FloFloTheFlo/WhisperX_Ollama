using System.Windows;
using WhisperXOllamaApp.ViewModels;

namespace WhisperXOllamaApp.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        if (DataContext is MainViewModel vm)
        {
            vm.InitializeAsync();
        }
    }
}
