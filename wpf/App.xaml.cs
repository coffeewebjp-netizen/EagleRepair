using System.IO;
using System.Text;
using System.Windows;

namespace CoffeeDiagnose;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
        catch (Exception exception)
        {
            var logDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CoffeeWeb", "TroubleRepair", "logs");
            Directory.CreateDirectory(logDirectory);
            var logPath = Path.Combine(logDirectory, "wpf-startup-error.log");
            File.WriteAllText(logPath, exception.ToString(), new UTF8Encoding(false));
            MessageBox.Show(
                $"CoffeeDiagnoseを起動できませんでした。\n\n{exception.Message}\n\n詳細: {logPath}",
                "起動エラー",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
