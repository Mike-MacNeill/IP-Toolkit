using System.Windows;
using System.Windows.Input;
using System.Diagnostics;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace IPToolkit.Windows;

public partial class MainWindow : Window
{
    private CancellationTokenSource? _networkCancellation;
    private CancellationTokenSource? _speedCancellation;
    private Forms.NotifyIcon? _trayIcon;
    private System.Drawing.Icon? _trayIconImage;
    private string? _mapUrl;
    private SubnetInfo? _currentSubnet;

    public MainWindow()
    {
        InitializeComponent();
        var darkMode = IsDarkModeEnabled();
        DarkModeCheckBox.IsChecked = darkMode;
        ApplyTheme(darkMode);
        SubnetInput.Text = "192.168.1.10/24";
        LoginCheckBox.IsChecked = IsLoginEnabled();
        try
        {
            var key = ToolkitServices.LoadApiKey();
            if (key is not null) ReputationStatus.Text = "An API key is saved in Windows Credential Manager.";
        }
        catch (Exception error) { ReputationStatus.Text = error.Message; }
        Calculate();
    }

    private void Theme_OnChanged(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        var darkMode = DarkModeCheckBox.IsChecked == true;
        ApplyTheme(darkMode);
        using var settings = Registry.CurrentUser.CreateSubKey(@"Software\IP Toolkit");
        settings.SetValue("DarkMode", darkMode ? 1 : 0, RegistryValueKind.DWord);
    }

    private static bool IsDarkModeEnabled()
    {
        using var settings = Registry.CurrentUser.OpenSubKey(@"Software\IP Toolkit");
        return settings?.GetValue("DarkMode") is int value && value == 1;
    }

    private static void ApplyTheme(bool darkMode)
    {
        var resources = System.Windows.Application.Current.Resources;
        var colors = darkMode
            ? new Dictionary<string, string>
            {
                ["WindowBackgroundBrush"] = "#141A19",
                ["SurfaceBackgroundBrush"] = "#1B2221",
                ["ControlBackgroundBrush"] = "#242D2B",
                ["PrimaryTextBrush"] = "#E6EFEC",
                ["SecondaryTextBrush"] = "#A7B7B2",
                ["BorderBrush"] = "#3D4B47",
                ["DangerTextBrush"] = "#FF8A80",
                ["GridLineBrush"] = "#33413D",
                ["GridHeaderBrush"] = "#242D2B"
            }
            : new Dictionary<string, string>
            {
                ["WindowBackgroundBrush"] = "#F4F6F5",
                ["SurfaceBackgroundBrush"] = "#FFFFFF",
                ["ControlBackgroundBrush"] = "#FFFFFF",
                ["PrimaryTextBrush"] = "#162A2A",
                ["SecondaryTextBrush"] = "#617170",
                ["BorderBrush"] = "#D8E0DD",
                ["DangerTextBrush"] = "#B42318",
                ["GridLineBrush"] = "#D8E0DD",
                ["GridHeaderBrush"] = "#EEF2F0"
            };

        foreach (var (key, color) in colors)
            resources[key] = new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(color));
    }

    private void Calculate_OnClick(object sender, RoutedEventArgs e) => Calculate();

    private void SubnetInput_OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            Calculate();
            e.Handled = true;
        }
    }

    private void Calculate()
    {
        if (!SubnetInfo.TryParse(SubnetInput.Text, out var subnet))
        {
            SubnetStatus.Text = "Enter a valid IPv4 or IPv6 address, CIDR, or IPv4 netmask.";
            ResultsGrid.ItemsSource = null;
            return;
        }

        SubnetStatus.Text = string.Empty;
        ResultsGrid.ItemsSource = subnet.Rows;
    }

    private async void MyIp_OnClick(object sender, RoutedEventArgs e)
    {
        GlobalStatus.Text = "Finding public addresses...";
        try
        {
            var result = await ToolkitServices.GetMyIpAsync(CancellationToken.None);
            GlobalStatus.Text = result;
            var preferred = result.Split(Environment.NewLine).FirstOrDefault()?.Split(':', 2).LastOrDefault()?.Trim();
            if (preferred is not null)
            {
                LookupInput.Text = preferred;
                SubnetInput.Text = preferred;
                ReputationInput.Text = preferred;
                NetworkInput.Text = preferred;
                switch (ToolsTabs.SelectedIndex)
                {
                    case 0: Lookup_OnClick(sender, new RoutedEventArgs()); break;
                    case 1: Calculate(); break;
                    case 2: Reputation_OnClick(sender, new RoutedEventArgs()); break;
                }
            }
        }
        catch (Exception error) { GlobalStatus.Text = error.Message; }
    }

    private async void Lookup_OnClick(object sender, RoutedEventArgs e)
    {
        LookupStatus.Text = "Looking up registration and location...";
        MapButton.IsEnabled = false;
        _mapUrl = null;
        try
        {
            LookupOutput.Text = await ToolkitServices.LookupAsync(LookupInput.Text, CancellationToken.None);
            var coordinate = LookupOutput.Text.Split(Environment.NewLine)
                .FirstOrDefault(line => line.StartsWith("Coordinates: ", StringComparison.Ordinal));
            if (coordinate is not null)
            {
                var pair = coordinate[13..].Split(',');
                if (pair.Length == 2) _mapUrl = $"https://www.bing.com/maps?cp={Uri.EscapeDataString(pair[0].Trim())}~{Uri.EscapeDataString(pair[1].Trim())}";
            }
            MapButton.IsEnabled = _mapUrl is not null;
            LookupStatus.Text = string.Empty;
        }
        catch (Exception error) { LookupStatus.Text = error.Message; }
    }

    private async void LookupInput_OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Lookup_OnClick(sender, new RoutedEventArgs()); e.Handled = true; }
    }

    private void OpenMap_OnClick(object sender, RoutedEventArgs e)
    {
        if (_mapUrl is not null) OpenUrl(_mapUrl);
    }

    private void SaveKey_OnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            ToolkitServices.SaveApiKey(ApiKeyBox.Password);
            ApiKeyBox.Clear();
            ReputationStatus.Text = "API key saved in Windows Credential Manager.";
        }
        catch (Exception error) { ReputationStatus.Text = error.Message; }
    }

    private void RemoveKey_OnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            ToolkitServices.RemoveApiKey();
            ApiKeyBox.Clear();
            ReputationStatus.Text = "Saved API key removed.";
        }
        catch (Exception error) { ReputationStatus.Text = error.Message; }
    }

    private async void Reputation_OnClick(object sender, RoutedEventArgs e)
    {
        ReputationStatus.Text = "Checking AbuseIPDB...";
        try
        {
            var key = ApiKeyBox.Password;
            if (string.IsNullOrEmpty(key)) key = ToolkitServices.LoadApiKey() ?? string.Empty;
            ReputationOutput.Text = await ToolkitServices.CheckReputationAsync(ReputationInput.Text, key, CancellationToken.None);
            ReputationStatus.Text = string.Empty;
        }
        catch (Exception error) { ReputationStatus.Text = error.Message; }
    }

    private async void ReputationInput_OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Reputation_OnClick(sender, new RoutedEventArgs()); e.Handled = true; }
    }

    private async void Network_OnClick(object sender, RoutedEventArgs e)
    {
        if (_networkCancellation is not null) return;
        _networkCancellation = new CancellationTokenSource();
        NetworkStartButton.IsEnabled = false;
        NetworkStopButton.IsEnabled = true;
        NetworkOutput.Clear();
        NetworkStatus.Text = string.Empty;
        var tool = (NetworkToolBox.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "Ping";
        var mode = (PortModeBox.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "Top 100";
        try
        {
            await ToolkitServices.RunNetworkCommandAsync(tool, NetworkInput.Text,
                int.TryParse(CountInput.Text, out var count) ? count : 5, ContinuousCheckBox.IsChecked == true,
                int.TryParse(HopsInput.Text, out var hops) ? hops : 30, ResolveCheckBox.IsChecked == true,
                mode, CustomPortsInput.Text,
                line => Dispatcher.Invoke(() => NetworkOutput.AppendText(line + Environment.NewLine)), _networkCancellation.Token);
            NetworkStatus.Text = "Command finished.";
        }
        catch (OperationCanceledException) { NetworkStatus.Text = "Stopped."; }
        catch (Exception error) { NetworkStatus.Text = error.Message; }
        finally
        {
            _networkCancellation.Dispose();
            _networkCancellation = null;
            NetworkStartButton.IsEnabled = true;
            NetworkStopButton.IsEnabled = false;
        }
    }

    private void StopNetwork_OnClick(object sender, RoutedEventArgs e) => _networkCancellation?.Cancel();

    private async void Speed_OnClick(object sender, RoutedEventArgs e)
    {
        if (_speedCancellation is not null) return;
        _speedCancellation = new CancellationTokenSource();
        SpeedStartButton.IsEnabled = false;
        SpeedStopButton.IsEnabled = true;
        SpeedOutput.Clear();
        var progress = new Progress<string>(text => SpeedStatus.Text = text);
        try { SpeedOutput.Text = await ToolkitServices.RunSpeedTestAsync(progress, _speedCancellation.Token); }
        catch (OperationCanceledException) { SpeedStatus.Text = "Speed test stopped."; }
        catch (Exception error) { SpeedStatus.Text = error.Message; }
        finally
        {
            _speedCancellation.Dispose();
            _speedCancellation = null;
            SpeedStartButton.IsEnabled = true;
            SpeedStopButton.IsEnabled = false;
        }
    }

    private void StopSpeed_OnClick(object sender, RoutedEventArgs e) => _speedCancellation?.Cancel();

    private void CopyLookup_OnClick(object sender, RoutedEventArgs e) => Copy(LookupOutput.Text);
    private void CopySubnet_OnClick(object sender, RoutedEventArgs e) => Copy(string.Join(Environment.NewLine,
        ResultsGrid.Items.Cast<SubnetRow>().Select(row => $"{row.Label}: {row.Value}")));
    private void CopyReputation_OnClick(object sender, RoutedEventArgs e) => Copy(ReputationOutput.Text);
    private void CopyNetwork_OnClick(object sender, RoutedEventArgs e) => Copy(NetworkOutput.Text);
    private void CopySpeed_OnClick(object sender, RoutedEventArgs e) => Copy(SpeedOutput.Text);

    private void Login_OnChanged(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", writable: true)
                           ?? Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            const string appName = "IP Toolkit";
            if (LoginCheckBox.IsChecked == true)
                run.SetValue(appName, $"\"{Environment.ProcessPath}\"");
            else
                run.DeleteValue(appName, throwOnMissingValue: false);
        }
        catch (Exception error)
        {
            System.Windows.MessageBox.Show(this, error.Message, "Open at login", MessageBoxButton.OK, MessageBoxImage.Error);
            LoginCheckBox.Checked -= Login_OnChanged;
            LoginCheckBox.Unchecked -= Login_OnChanged;
            LoginCheckBox.IsChecked = IsLoginEnabled();
            LoginCheckBox.Checked += Login_OnChanged;
            LoginCheckBox.Unchecked += Login_OnChanged;
        }
    }

    private bool IsLoginEnabled()
    {
        using var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return run?.GetValue("IP Toolkit") is not null;
    }

    private void Minimize_OnClick(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }

    private void Maximize_OnClick(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    protected override void OnStateChanged(EventArgs e)
    {
        base.OnStateChanged(e);
        if (MaximizeButton is not null)
            MaximizeButton.Content = WindowState == WindowState.Maximized ? "Restore" : "Maximize";
        if (WindowState == WindowState.Minimized) HideToTray();
    }

    private void HideToTray()
    {
        ShowInTaskbar = false;
        Hide();
        _trayIcon ??= CreateTrayIcon();
        _trayIcon.Visible = true;
    }

    private Forms.NotifyIcon CreateTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open IP Toolkit", null, (_, _) => RestoreFromTray());
        menu.Items.Add("Exit", null, (_, _) => Close());
        var executablePath = Environment.ProcessPath;
        _trayIconImage = executablePath is null ? null : System.Drawing.Icon.ExtractAssociatedIcon(executablePath);
        var icon = new Forms.NotifyIcon
        {
            Icon = _trayIconImage ?? System.Drawing.SystemIcons.Application,
            Text = "IP Toolkit",
            ContextMenuStrip = menu
        };
        icon.DoubleClick += (_, _) => RestoreFromTray();
        return icon;
    }

    private void RestoreFromTray()
    {
        ShowInTaskbar = true;
        Show();
        WindowState = WindowState.Normal;
        Activate();
        if (_trayIcon is not null) _trayIcon.Visible = false;
    }

    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();

    protected override void OnClosed(EventArgs e)
    {
        _networkCancellation?.Cancel();
        _speedCancellation?.Cancel();
        _trayIcon?.Dispose();
        _trayIconImage?.Dispose();
        base.OnClosed(e);
    }

    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    private static void Copy(string text)
    {
        if (!string.IsNullOrWhiteSpace(text)) System.Windows.Clipboard.SetText(text);
    }

    private void SplitSubnet_OnClick(object sender, RoutedEventArgs e)
    {
        if (_currentSubnet is null || !int.TryParse(SplitPrefixInput.Text, out var prefix))
        {
            SubnetStatus.Text = "Enter a valid prefix length before splitting.";
            return;
        }
        var subnets = _currentSubnet.Split(prefix);
        if (subnets.Count == 0)
        {
            SubnetStatus.Text = "The split prefix must be longer than the current prefix and within the address family range.";
            return;
        }
        SubnetStatus.Text = subnets.Count == 1024 ? "Showing the first 1,024 subnets." : string.Empty;
        ResultsGrid.ItemsSource = subnets;
    }

    private void CopySubnets_OnClick(object sender, RoutedEventArgs e) => Copy(string.Join(Environment.NewLine,
        ResultsGrid.Items.Cast<SubnetRow>().Select(row => row.Value)));
}