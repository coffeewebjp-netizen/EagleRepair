using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CoffeeDiagnose;

public partial class MainWindow : Window
{
    private readonly string _root;
    private readonly string _logRoot;
    private bool _isBusy;
    private string? _currentLogPath;

    public ObservableCollection<ModuleViewModel> Modules { get; } = [];

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        _root = FindRepositoryRoot();
        _logRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CoffeeWeb", "TroubleRepair", "logs");
        Loaded += async (_, _) => await LoadModulesAsync();
    }

    private async Task LoadModulesAsync()
    {
        try
        {
            GlobalStatus.Text = "修復モジュールを読み込んでいます…";
            var script = Path.Combine(_root, "tools", "get-troubleshooter-modules.ps1");
            var startInfo = CreatePowerShellStartInfo(script);
            startInfo.ArgumentList.Add("-Root");
            startInfo.ArgumentList.Add(_root);
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            startInfo.StandardOutputEncoding = Encoding.UTF8;
            startInfo.StandardErrorEncoding = Encoding.UTF8;

            using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("PowerShellを起動できませんでした。");
            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            var output = await outputTask;
            var error = await errorTask;
            if (process.ExitCode != 0)
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "モジュール一覧を取得できませんでした。" : error.Trim());

            var definitions = JsonSerializer.Deserialize<List<ModuleDefinitionDto>>(output.Trim(), JsonOptions) ?? [];
            foreach (var definition in definitions.OrderBy(x => x.Order))
            {
                Modules.Add(new ModuleViewModel
                {
                    Id = definition.Id,
                    DisplayName = definition.DisplayName,
                    Description = definition.Description,
                    SupportsDiagnose = definition.SupportsDiagnose,
                    SupportsRepair = definition.SupportsRepair,
                    RepairRequiresAdmin = definition.RepairRequiresAdmin,
                    Order = definition.Order
                });
            }

            DiagnoseAllButton.IsEnabled = Modules.Any(x => x.SupportsDiagnose);
            GlobalStatus.Text = Modules.Count == 0
                ? "有効な修復モジュールがありません。"
                : $"準備完了  •  {Modules.Count}個のモジュール";
        }
        catch (Exception exception)
        {
            DiagnoseAllButton.IsEnabled = false;
            GlobalStatus.Text = "モジュールを読み込めませんでした。";
            LogBox.Text = exception.Message;
            ActivityDot.Fill = BrushFrom("#D92D20");
        }
    }

    private async void Diagnose_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ModuleViewModel module })
            await ExecuteModuleAsync(module, "Diagnose");
    }

    private async void Repair_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ModuleViewModel module }) return;
        var answer = MessageBox.Show(
            this,
            $"{module.DisplayName} の診断と修復を実行します。\n\n関連アプリやサービスが一時的に再起動することがあります。続行しますか？",
            "修復の確認",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question,
            MessageBoxResult.No);
        if (answer == MessageBoxResult.Yes)
            await ExecuteModuleAsync(module, "Repair");
    }

    private async void DiagnoseAll_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy) return;
        foreach (var module in Modules.Where(x => x.SupportsDiagnose))
            await ExecuteModuleAsync(module, "Diagnose");
        GlobalStatus.Text = "すべての診断が完了しました。各カードの結果を確認してください。";
    }

    private async Task<bool> ExecuteModuleAsync(ModuleViewModel module, string mode)
    {
        if (_isBusy) return false;
        _isBusy = true;
        SetActionsEnabled(false);
        module.SetRunning(mode);
        ActivityDot.Fill = BrushFrom("#F79009");
        LogTitle.Text = $"{module.DisplayName}  •  {(mode == "Repair" ? "修復" : "診断")}";
        LogBox.Text = "処理を開始しています…";
        GlobalStatus.Text = $"{module.DisplayName} を{(mode == "Repair" ? "修復" : "診断")}しています…";

        Directory.CreateDirectory(_logRoot);
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff");
        _currentLogPath = Path.Combine(_logRoot, $"{stamp}-{module.Id}-{mode.ToLowerInvariant()}.log");
        var resultPath = Path.Combine(_logRoot, $"{stamp}-{module.Id}-{mode.ToLowerInvariant()}.json");

        try
        {
            var runner = Path.Combine(_root, "tools", "invoke-troubleshooter-module.ps1");
            var elevated = mode == "Repair" && module.RepairRequiresAdmin;
            var startInfo = CreatePowerShellStartInfo(runner, elevated);
            AddRunnerArguments(startInfo, module.Id, mode, _currentLogPath, resultPath);

            using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("修復処理を起動できませんでした。");
            var deadline = DateTime.UtcNow.AddMinutes(15);
            while (!process.HasExited && DateTime.UtcNow < deadline)
            {
                await RefreshLogAsync(_currentLogPath);
                await Task.Delay(400);
            }
            await Task.Delay(250);
            await RefreshLogAsync(_currentLogPath);

            if (!process.HasExited)
                throw new TimeoutException("15分以内に処理が完了しませんでした。処理自体はバックグラウンドで継続している可能性があります。");

            RunResultDto? result = null;
            if (File.Exists(resultPath))
            {
                var json = await ReadSharedTextAsync(resultPath);
                result = JsonSerializer.Deserialize<RunResultDto>(json, JsonOptions);
            }
            var success = result?.Success ?? process.ExitCode == 0;
            module.SetCompleted(success);
            ActivityDot.Fill = BrushFrom(success ? "#12B76A" : "#D92D20");
            GlobalStatus.Text = success
                ? $"{module.DisplayName} は正常に完了しました。"
                : $"{module.DisplayName} を完了できませんでした。ログを確認してください。";
            return success;
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            module.SetCompleted(false);
            ActivityDot.Fill = BrushFrom("#98A2B3");
            LogBox.Text = "管理者権限の確認がキャンセルされました。変更は行われていません。";
            GlobalStatus.Text = "修復をキャンセルしました。";
            return false;
        }
        catch (Exception exception)
        {
            module.SetCompleted(false);
            ActivityDot.Fill = BrushFrom("#D92D20");
            LogBox.Text = File.Exists(_currentLogPath)
                ? (await ReadSharedTextAsync(_currentLogPath)) + Environment.NewLine + Environment.NewLine + "ERROR: " + exception.Message
                : "ERROR: " + exception.Message;
            GlobalStatus.Text = "処理中にエラーが発生しました。";
            return false;
        }
        finally
        {
            _isBusy = false;
            SetActionsEnabled(true);
        }
    }

    private static ProcessStartInfo CreatePowerShellStartInfo(string script, bool elevated = false)
    {
        var startInfo = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = elevated,
            CreateNoWindow = !elevated,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        if (elevated) startInfo.Verb = "runas";
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-WindowStyle");
        startInfo.ArgumentList.Add("Hidden");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(script);
        return startInfo;
    }

    private static void AddRunnerArguments(ProcessStartInfo startInfo, string moduleId, string mode, string logPath, string resultPath)
    {
        startInfo.ArgumentList.Add("-ModuleId");
        startInfo.ArgumentList.Add(moduleId);
        startInfo.ArgumentList.Add("-Mode");
        startInfo.ArgumentList.Add(mode);
        startInfo.ArgumentList.Add("-LogPath");
        startInfo.ArgumentList.Add(logPath);
        startInfo.ArgumentList.Add("-ResultPath");
        startInfo.ArgumentList.Add(resultPath);
    }

    private async Task RefreshLogAsync(string path)
    {
        if (!File.Exists(path)) return;
        var text = await ReadSharedTextAsync(path);
        if (LogBox.Text == text) return;
        LogBox.Text = text;
        LogBox.CaretIndex = LogBox.Text.Length;
        LogBox.ScrollToEnd();
    }

    private static async Task<string> ReadSharedTextAsync(string path)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return await reader.ReadToEndAsync();
    }

    private void SetActionsEnabled(bool enabled)
    {
        foreach (var module in Modules) module.SetActionsEnabled(enabled);
        DiagnoseAllButton.IsEnabled = enabled && Modules.Any(x => x.SupportsDiagnose);
    }

    private void CopyLog_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(LogBox.Text))
        {
            Clipboard.SetText(LogBox.Text);
            GlobalStatus.Text = "ログをクリップボードへコピーしました。";
        }
    }

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_logRoot);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_logRoot}\"") { UseShellExecute = true });
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (!_isBusy) return;
        var answer = MessageBox.Show(
            this,
            "診断または修復を実行中です。画面を閉じても処理は継続する場合があります。閉じますか？",
            "実行中の処理",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        e.Cancel = answer != MessageBoxResult.Yes;
    }

    private static string FindRepositoryRoot()
    {
        var environmentRoot = Environment.GetEnvironmentVariable("TROUBLE_REPAIR_ROOT");
        if (!string.IsNullOrWhiteSpace(environmentRoot) && IsRepositoryRoot(environmentRoot))
            return Path.GetFullPath(environmentRoot);

        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            if (IsRepositoryRoot(directory.FullName)) return directory.FullName;
        }
        throw new DirectoryNotFoundException("TroubleRepairのルートフォルダーを見つけられませんでした。");
    }

    private static bool IsRepositoryRoot(string path) =>
        Directory.Exists(Path.Combine(path, "modules")) &&
        File.Exists(Path.Combine(path, "tools", "invoke-troubleshooter-module.ps1"));

    private static Brush BrushFrom(string color)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        brush.Freeze();
        return brush;
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private sealed record ModuleDefinitionDto(
        string Id,
        string DisplayName,
        string Description,
        bool SupportsDiagnose,
        bool SupportsRepair,
        bool RepairRequiresAdmin,
        int Order);

    private sealed record RunResultDto(bool Success, int ExitCode, string? Message);
}
