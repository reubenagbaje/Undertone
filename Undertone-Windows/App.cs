using System;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Undertone;
public sealed class App : Application
{
    Mutex? instance;
    Forms.NotifyIcon? tray;
    public static void UI(Action action) { if (Current?.Dispatcher is { } d && !d.HasShutdownStarted) d.BeginInvoke(action); }
    [STAThread] public static void Main() { var app = new App(); app.Run(); }
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = new Mutex(true, "Local\\Undertone.Windows", out bool first);
        if (!first) { Shutdown(); return; }
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var prefs = Preferences.Load(); var window = new IslandWindow(prefs); MainWindow = window;
        tray = new Forms.NotifyIcon { Text = "Undertone", Icon = System.Drawing.SystemIcons.Application, Visible = true };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open player", null, (_,_) => UI(window.OpenPlayer));
        menu.Items.Add("Settings", null, (_,_) => UI(window.OpenSettings));
        menu.Items.Add("Presentation mode", null, (_,_) => UI(window.TogglePresentation));
        menu.Items.Add("Quit", null, (_,_) => UI(Shutdown));
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_,_) => UI(window.OpenPlayer);
        window.Show();
        SystemEvents.SessionSwitch += SessionSwitch;
        SystemEvents.PowerModeChanged += PowerChanged;
        SystemEvents.DisplaySettingsChanged += DisplayChanged;
    }
    void SessionSwitch(object sender, SessionSwitchEventArgs e) => UI(() => { if (MainWindow is IslandWindow w) w.SetSuspended(e.Reason == SessionSwitchReason.SessionLock); });
    void PowerChanged(object sender, PowerModeChangedEventArgs e) => UI(() => { if (MainWindow is IslandWindow w) w.SetSuspended(e.Mode == PowerModes.Suspend); });
    void DisplayChanged(object? sender, EventArgs e) => UI(() => (MainWindow as IslandWindow)?.Position());
    protected override void OnExit(ExitEventArgs e) { SystemEvents.SessionSwitch -= SessionSwitch; SystemEvents.PowerModeChanged -= PowerChanged; SystemEvents.DisplaySettingsChanged -= DisplayChanged; tray?.Dispose(); (MainWindow as IslandWindow)?.Dispose(); instance?.Dispose(); base.OnExit(e); }
}
