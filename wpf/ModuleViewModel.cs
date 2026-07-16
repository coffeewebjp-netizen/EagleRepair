using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;

namespace CoffeeDiagnose;

public sealed class ModuleViewModel : INotifyPropertyChanged
{
    private static readonly Brush ReadyBrush = CreateBrush("#EEF0FF");
    private static readonly Brush RunningBrush = CreateBrush("#FFF4D6");
    private static readonly Brush SuccessBrush = CreateBrush("#E8F8EF");
    private static readonly Brush FailedBrush = CreateBrush("#FDECEC");
    private static readonly Brush ReadyTextBrush = CreateBrush("#4B57CF");
    private static readonly Brush RunningTextBrush = CreateBrush("#9A6700");
    private static readonly Brush SuccessTextBrush = CreateBrush("#177245");
    private static readonly Brush FailedTextBrush = CreateBrush("#B42318");

    private bool _actionsEnabled = true;
    private string _statusText = "待機中";
    private Brush _statusBackground = ReadyBrush;
    private Brush _statusForeground = ReadyTextBrush;

    public required string Id { get; init; }
    public required string DisplayName { get; init; }
    public required string Description { get; init; }
    public bool SupportsDiagnose { get; init; }
    public bool SupportsRepair { get; init; }
    public bool RepairRequiresAdmin { get; init; }
    public int Order { get; init; }

    public string Initials => DisplayName.Length == 0 ? "?" : DisplayName[..1].ToUpperInvariant();
    public bool CanDiagnose => _actionsEnabled && SupportsDiagnose;
    public bool CanRepair => _actionsEnabled && SupportsRepair;
    public string StatusText { get => _statusText; private set => SetField(ref _statusText, value); }
    public Brush StatusBackground { get => _statusBackground; private set => SetField(ref _statusBackground, value); }
    public Brush StatusForeground { get => _statusForeground; private set => SetField(ref _statusForeground, value); }

    public void SetActionsEnabled(bool enabled)
    {
        _actionsEnabled = enabled;
        OnPropertyChanged(nameof(CanDiagnose));
        OnPropertyChanged(nameof(CanRepair));
    }

    public void SetRunning(string mode)
    {
        StatusText = mode == "Repair" ? "修復中" : "診断中";
        StatusBackground = RunningBrush;
        StatusForeground = RunningTextBrush;
    }

    public void SetCompleted(bool success)
    {
        StatusText = success ? "正常に完了" : "要確認";
        StatusBackground = success ? SuccessBrush : FailedBrush;
        StatusForeground = success ? SuccessTextBrush : FailedTextBrush;
    }

    private static Brush CreateBrush(string color)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        brush.Freeze();
        return brush;
    }

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnPropertyChanged(propertyName);
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    public event PropertyChangedEventHandler? PropertyChanged;
}
