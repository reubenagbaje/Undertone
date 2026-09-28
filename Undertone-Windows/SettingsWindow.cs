using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace Undertone;
public sealed class SettingsWindow : Window
{
    public SettingsWindow(Preferences p, IslandWindow island, SpotifyAccount account)
    {
        Title="Undertone Settings";Width=620;Height=700;MinWidth=540;MinHeight=550;Background=new SolidColorBrush(Color.FromRgb(16,16,17));Foreground=Brushes.White;
        FontFamily=new FontFamily("Segoe UI Variable Display");WindowStartupLocation=WindowStartupLocation.CenterScreen;
        var root=new DockPanel{Margin=new Thickness(24)};Content=root;
        var header=IslandWindow.Text("Undertone",24,Brushes.White,FontWeights.Bold);header.Margin=new Thickness(0,0,0,20);DockPanel.SetDock(header,Dock.Top);root.Children.Add(header);
        var credit=IslandWindow.Text("Made by Reuben Agbaje",11,IslandWindow.Muted);credit.Margin=new Thickness(0,16,0,0);DockPanel.SetDock(credit,Dock.Bottom);root.Children.Add(credit);
        var tabs=new TabControl{Background=Background,Foreground=Brushes.White,BorderThickness=new Thickness(0)};root.Children.Add(tabs);
        StackPanel Page(string title){var content=new StackPanel{Margin=new Thickness(14)};tabs.Items.Add(new TabItem{Header=title,Content=new ScrollViewer{Content=content,VerticalScrollBarVisibility=ScrollBarVisibility.Auto},Background=Background,Foreground=Brushes.Gray});return content;}
        void Toggle(StackPanel page,string title,bool initial,Action<bool> set){var c=new CheckBox{Content=title,IsChecked=initial,Foreground=Brushes.White,Margin=new Thickness(0,10,0,10)};c.Click+=(_,_)=>{set(c.IsChecked==true);island.ApplyPreferences();};page.Children.Add(c);}
        void Note(StackPanel page,string text){var t=IslandWindow.Text(text,12,IslandWindow.Muted);t.TextWrapping=TextWrapping.Wrap;t.Margin=new Thickness(0,8,0,12);page.Children.Add(t);}
        var general=Page("General");
        Toggle(general,"Prefer Spotify when available",p.PreferSpotify,v=>p.PreferSpotify=v);
        Toggle(general,"Reactive system-audio waveform",p.EnableAudio,v=>p.EnableAudio=v);
        Note(general,"Audio is analysed locally and never saved. This Windows preview captures the output device, including other apps.");
        general.Children.Add(IslandWindow.Text("Spotify library & queue",16,Brushes.White,FontWeights.SemiBold));
        Note(general,"Basic playback works without signing in. For likes and queue, enter your Spotify Developer Client ID and register this redirect: http://127.0.0.1:43821/callback/");
        var client=new TextBox{Text=p.SpotifyClientId,Height=30,Margin=new Thickness(0,8,0,8)};general.Children.Add(client);
        var status=IslandWindow.Text(account.Connected?"Spotify account connected":"Not connected",12,IslandWindow.Muted);status.TextWrapping=TextWrapping.Wrap;
        general.Children.Add(IslandWindow.Button("Connect Spotify",async()=>{p.SpotifyClientId=client.Text.Trim();p.Save();try{status.Text="Complete sign-in in your browser…";await account.Connect();status.Text="Connected. Tokens refresh automatically.";}catch(Exception e){status.Text=e.Message;}}));
        general.Children.Add(IslandWindow.Button("Disconnect",()=>{account.Disconnect();status.Text="Disconnected";}));general.Children.Add(status);
        general.Children.Add(IslandWindow.Button("Check GitHub releases",()=>Process.Start(new ProcessStartInfo("https://github.com/reubenagbaje/Undertone/releases"){UseShellExecute=true})));
        Note(general,"Windows preview updates are manual. Ctrl+Alt+P hides/restores Undertone. Use the system tray to reopen settings or quit.");
        var modules=Page("Modules");Toggle(modules,"Timers",p.EnableTimers,v=>p.EnableTimers=v);Toggle(modules,"File shelf — open on file drag",p.EnableShelf,v=>p.EnableShelf=v);Toggle(modules,"HTTPS downloads",p.EnableDownloads,v=>p.EnableDownloads=v);Toggle(modules,"System volume slider",p.EnableVolume,v=>p.EnableVolume=v);Toggle(modules,"Built-in display brightness slider",p.EnableBrightness,v=>p.EnableBrightness=v);
        Note(modules,"Brightness support depends on the monitor. The preview hides on the Windows lock screen; it does not draw over password prompts.");
        var appearance=Page("Appearance");Toggle(appearance,"Notch attached to top edge",p.NotchStyle,v=>p.NotchStyle=v);Toggle(appearance,"Always show island",p.AlwaysShow,v=>p.AlwaysShow=v);Toggle(appearance,"White outline",p.Outline,v=>p.Outline=v);Toggle(appearance,"Reverse horizontal swipe",p.ReverseSwipe,v=>p.ReverseSwipe=v);Toggle(appearance,"Reduce motion",p.ReduceMotion,v=>p.ReduceMotion=v);
        appearance.Children.Add(IslandWindow.Text("Display",12,IslandWindow.Muted));var displays=new ComboBox{Margin=new Thickness(0,8,0,12)};foreach(var screen in Forms.Screen.AllScreens)displays.Items.Add(screen.DeviceName);displays.SelectedItem=p.Display;displays.SelectionChanged+=(_,_)=>{if(displays.SelectedItem is string name){p.Display=name;island.ApplyPreferences();}};appearance.Children.Add(displays);
        appearance.Children.Add(IslandWindow.Text("Distance from top edge",12,IslandWindow.Muted));var gap=new Slider{Minimum=4,Maximum=80,Value=p.Gap,Margin=new Thickness(0,8,0,12)};gap.ValueChanged+=(_,_)=>{p.Gap=gap.Value;island.Position();p.Save();};appearance.Children.Add(gap);
    }
}
