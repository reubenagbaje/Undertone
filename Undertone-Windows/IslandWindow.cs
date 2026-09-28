using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Undertone;
public sealed class IslandWindow : Window, IDisposable
{
    readonly Preferences prefs;
    readonly MediaEngine media;
    readonly AudioEngine audio = new();
    readonly SpotifyAccount spotify;
    readonly Countdown countdown = new();
    readonly Border shell = new();
    readonly Grid body = new();
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(250) };
    readonly DispatcherTimer hover = new() { Interval = TimeSpan.FromMilliseconds(320) };
    readonly DispatcherTimer leave = new() { Interval = TimeSpan.FromMilliseconds(500) };
    readonly DispatcherTimer waveTick = new() { Interval = TimeSpan.FromMilliseconds(33) };
    readonly DispatcherTimer swipeEnd = new() { Interval = TimeSpan.FromMilliseconds(160) };
    readonly List<string> files = new();
    readonly List<Rectangle> bars = new();
    readonly HttpClient downloader = new() { Timeout = Timeout.InfiniteTimeSpan };
    CancellationTokenSource? download;
    bool expanded, timerFocused = true, suspended, presentation, seeking, disposed;
    string panel = "", previousTitle = "", status = "";
    DateTimeOffset statusUntil;
    double swipe;
    TextBlock? elapsed, remaining, timerText, statusText;
    Slider? progress;
    SettingsWindow? settings;
    HwndSource? source;
    public static readonly Brush Muted = new SolidColorBrush(Color.FromRgb(135,135,140));
    public static readonly Brush Orange = new SolidColorBrush(Color.FromRgb(255,159,10));
    static readonly Brush Surface = new SolidColorBrush(Color.FromRgb(28,28,30));
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    public IslandWindow(Preferences preferences)
    {
        prefs = preferences; media = new(prefs); spotify = new(prefs);
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ShowActivated = false; Width = 440; Height = 560;
        FontFamily = new FontFamily("Segoe UI Variable Display"); Foreground = Brushes.White;
        shell.Background = Brushes.Black; shell.HorizontalAlignment = HorizontalAlignment.Center; shell.VerticalAlignment = VerticalAlignment.Top; shell.Margin = new Thickness(12,0,12,18); shell.Child = body;
        shell.Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 16, ShadowDepth = 5, Opacity = .3 };
        var outer = new Grid(); outer.Children.Add(shell); Content = outer;
        shell.MouseEnter += (_,_) => { leave.Stop(); if (!expanded) { hover.Stop(); hover.Start(); } };
        shell.MouseLeave += (_,_) => { hover.Stop(); leave.Start(); };
        hover.Tick += (_,_) => { hover.Stop(); if (swipe == 0 && shell.IsMouseOver) OpenPlayer(); };
        leave.Tick += (_,_) => { leave.Stop(); if (!shell.IsMouseOver && Mouse.LeftButton != MouseButtonState.Pressed) Collapse(); };
        AllowDrop = true;
        DragEnter += DragReveal; DragOver += DragReveal;
        Drop += (_,e) => { if (!prefs.EnableShelf || presentation || !e.Data.GetDataPresent(DataFormats.FileDrop)) return; foreach (var file in (string[])e.Data.GetData(DataFormats.FileDrop)) if (files.Count < 20 && File.Exists(file) && !files.Contains(file)) files.Add(file); e.Effects = DragDropEffects.Copy; e.Handled = true; panel="Files"; expanded=true; Render(); };
        DragLeave += (_,_) => leave.Start();
        PreviewKeyDown += (_,e) => { if (e.Key == Key.OemComma && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { OpenSettings(); e.Handled = true; } if (e.Key == Key.Escape) Collapse(); };
        media.Changed += MediaChanged; media.Error += Notify; audio.Error += Notify;
        tick.Tick += (_,_) => Tick(); tick.Start();
        waveTick.Tick += (_,_) => { var levels = audio.Levels; for (int i=0;i<bars.Count;i++) bars[i].Height = Math.Clamp(3 + (media.Playing ? levels[i%4] : 0) * 18, 3, 21); };
        swipeEnd.Tick += async (_,_) => { swipeEnd.Stop(); double amount=swipe; swipe=0; shell.RenderTransform = Transform.Identity; if (Math.Abs(amount)>=120) await Skip(amount > 0 ? "next" : "previous"); };
        SourceInitialized += (_,_) => { source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle); source?.AddHook(Hook); if(source != null) RegisterHotKey(source.Handle,1,0x0003,0x50); Position(); };
        Loaded += async (_,_) => { await media.Start(); ApplyPreferences(); };
        Render();
    }
    void DragReveal(object sender, DragEventArgs e)
    {
        if (!prefs.EnableShelf || presentation || !e.Data.GetDataPresent(DataFormats.FileDrop)) { e.Effects=DragDropEffects.None; return; }
        e.Effects=DragDropEffects.Copy; e.Handled=true; hover.Stop(); leave.Stop();
        if (!expanded || panel!="Files") { expanded=true; panel="Files"; Render(); }
    }
    IntPtr Hook(IntPtr hwnd,int msg,IntPtr wParam,IntPtr lParam,ref bool handled)
    {
        if(msg==0x0312 && wParam.ToInt32()==1) { TogglePresentation(); handled=true; }
        if(msg==0x020E && shell.IsMouseOver && panel=="") {
            short delta=(short)((wParam.ToInt64()>>16)&0xffff); swipe+=delta*(prefs.ReverseSwipe?-1:1); hover.Stop();
            if(!prefs.ReduceMotion) shell.RenderTransform = new ScaleTransform(1+Math.Min(.16,Math.Abs(swipe)/1400),1,shell.ActualWidth/2,0);
            swipeEnd.Stop();swipeEnd.Start();handled=true;
        }
        return IntPtr.Zero;
    }
    void MediaChanged()
    {
        bool changed=previousTitle!=media.Title; previousTitle=media.Title;
        if(changed && media.Connected && !expanded) { status=media.Title;statusUntil=DateTimeOffset.UtcNow.AddSeconds(3); }
        Render(); UpdateWaveTimer();
    }
    public void Notify(string message) { status=message;statusUntil=DateTimeOffset.UtcNow.AddSeconds(7);if(statusText!=null)statusText.Text=message; }
    void Tick()
    {
        if(suspended || presentation) return;
        if(countdown.Tick(DateTimeOffset.UtcNow)) { System.Media.SystemSounds.Exclamation.Play();timerFocused=true;Render(); }
        if(timerText!=null) timerText.Text=Countdown.Format(countdown.Remaining(DateTimeOffset.UtcNow));
        if(progress!=null && !seeking) { progress.Maximum=Math.Max(1,media.Duration);progress.Value=media.Position; }
        if(elapsed!=null)elapsed.Text=Countdown.Format(TimeSpan.FromSeconds(seeking ? progress?.Value??0 : media.Position));
        if(remaining!=null)remaining.Text="-"+Countdown.Format(TimeSpan.FromSeconds(Math.Max(0,media.Duration-(seeking?progress?.Value??0:media.Position))));
        if(statusText!=null && DateTimeOffset.UtcNow>statusUntil && panel=="")statusText.Text="";
        if(!expanded && !prefs.AlwaysShow && !media.Playing && !countdown.Active) shell.Opacity=shell.IsMouseOver?1:.06; else shell.Opacity=1;
    }
    void UpdateWaveTimer() { if(prefs.EnableAudio && media.Playing && !suspended && !presentation)waveTick.Start();else { waveTick.Stop();foreach(var bar in bars)bar.Height=3; } }
    public void Position()
    {
        var screen=Forms.Screen.AllScreens.FirstOrDefault(s=>s.DeviceName==prefs.Display)??Forms.Screen.PrimaryScreen!;
        var dpi=VisualTreeHelper.GetDpi(this);
        Left=(screen.WorkingArea.Left+screen.WorkingArea.Width/2.0)/dpi.DpiScaleX-Width/2;
        Top=screen.WorkingArea.Top/dpi.DpiScaleY+(prefs.NotchStyle?0:prefs.Gap);
    }
    public void OpenPlayer() { presentation=false;Show();hover.Stop();expanded=true;Render(); }
    void Collapse() { expanded=false;panel="";timerFocused=true;Render(); }
    public void TogglePresentation() { presentation=!presentation;if(presentation)Hide();else Show();UpdateWaveTimer(); }
    public void SetSuspended(bool value) { suspended=value;if(value){Hide();audio.Stop();tick.Stop();}else{if(!presentation)Show();tick.Start();if(prefs.EnableAudio)audio.Start();}UpdateWaveTimer(); }
    public void ApplyPreferences() { prefs.Save();if(!prefs.EnableTimers)countdown.Cancel();if(!prefs.EnableShelf){files.Clear();if(panel=="Files")panel="";}if(!prefs.EnableDownloads)download?.Cancel();if(prefs.EnableAudio && !suspended)audio.Start();else audio.Stop();media.Select();Position();Render();UpdateWaveTimer(); }
    public void OpenSettings() { if(settings==null){settings=new SettingsWindow(prefs,this,spotify);settings.Closed+=(_,_)=>settings=null;}settings.Show();settings.Activate(); }
    public static TextBlock Text(string text,double size=12,Brush? color=null,FontWeight? weight=null) => new() { Text=text,FontSize=size,Foreground=color??Brushes.White,FontWeight=weight??FontWeights.Normal,VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis };
    public static Button Button(string text,Action action,string? tooltip=null,double size=12)
    {
        var button=new Button { Content=Text(text,size),ToolTip=tooltip??text,Background=Brushes.Transparent,BorderThickness=new Thickness(0),Padding=new Thickness(10,7,10,7),Cursor=Cursors.Hand,MinHeight=28,VerticalContentAlignment=VerticalAlignment.Center,HorizontalContentAlignment=HorizontalAlignment.Center };
        var template=new ControlTemplate(typeof(Button));var border=new FrameworkElementFactory(typeof(Border));border.SetValue(Border.CornerRadiusProperty,new CornerRadius(18));border.SetValue(Border.BackgroundProperty,new TemplateBindingExtension(Control.BackgroundProperty));
        var content=new FrameworkElementFactory(typeof(ContentPresenter));content.SetValue(FrameworkElement.MarginProperty,new TemplateBindingExtension(Control.PaddingProperty));content.SetValue(FrameworkElement.HorizontalAlignmentProperty,HorizontalAlignment.Center);content.SetValue(FrameworkElement.VerticalAlignmentProperty,VerticalAlignment.Center);border.AppendChild(content);template.VisualTree=border;button.Template=template;
        button.MouseEnter+=(_,_)=>button.Background=new SolidColorBrush(Color.FromArgb(28,255,255,255));button.MouseLeave+=(_,_)=>button.Background=Brushes.Transparent;
        button.Click+=(_,_)=>action();return button;
    }
    StackPanel Wave()
    {
        var row=new StackPanel { Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center };
        for(int i=0;i<4;i++){var r=new Rectangle{Width=3,Height=3,RadiusX=1.5,RadiusY=1.5,Fill=Muted,Margin=new Thickness(1.5,0,1.5,0),VerticalAlignment=VerticalAlignment.Center};bars.Add(r);row.Children.Add(r);}return row;
    }
    Border Artwork(double size)
    {
        var border=new Border{Width=size,Height=size,CornerRadius=new CornerRadius(size>40?10:5),Background=Surface,ClipToBounds=true};
        if(media.Artwork!=null){var image=new Image{Source=media.Artwork,Stretch=Stretch.UniformToFill};image.Clip=new RectangleGeometry(new Rect(0,0,size,size),size>40?10:5,size>40?10:5);border.Child=image;}else border.Child=Text("♫",size*.4,Muted);
        return border;
    }
    void Animate(double height,double width)
    {
        shell.CornerRadius=prefs.NotchStyle?new CornerRadius(0,0,expanded?42:18,expanded?42:18):new CornerRadius(expanded?36:22);
        shell.BorderBrush=prefs.Outline?new SolidColorBrush(Color.FromArgb(140,255,255,255)):Brushes.Transparent;shell.BorderThickness=new Thickness(.75);
        var duration=TimeSpan.FromSeconds(prefs.ReduceMotion?0:.32);
        shell.BeginAnimation(FrameworkElement.HeightProperty,new DoubleAnimation(height,duration){EasingFunction=new BackEase{Amplitude=.12*prefs.AnimationStrength,EasingMode=EasingMode.EaseOut}});
        shell.BeginAnimation(FrameworkElement.WidthProperty,new DoubleAnimation(width,duration){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}});
    }
    void Render()
    {
        body.Children.Clear();bars.Clear();progress=null;elapsed=remaining=timerText=statusText=null;
        bool timer=prefs.EnableTimers && countdown.Active;
        if(!expanded) {
            var row=new Grid{Margin=new Thickness(12,0,12,0)};row.ColumnDefinitions.Add(new(){Width=new GridLength(36)});row.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new(){Width=new GridLength(timer?75:28)});
            row.Children.Add(timer?Text("◷",22,Orange):Artwork(26));
            var right=timer? (UIElement)(timerText=Text(Countdown.Format(countdown.Remaining(DateTimeOffset.UtcNow)),16,Orange)):Wave();Grid.SetColumn(right,2);row.Children.Add(right);body.Children.Add(row);
            row.MouseLeftButtonUp+=(_,_)=>OpenPlayer();Animate(42,timer?270:240);return;
        }
        var stack=new StackPanel{Margin=new Thickness(24,20,24,20)};body.Children.Add(stack);
        if(timer && timerFocused && panel=="") {
            stack.Children.Add(TimerCard());
            var footer=new DockPanel{Margin=new Thickness(0,12,0,0)};var tools=Button("Tools",()=>{panel="Activities";Render();});DockPanel.SetDock(tools,Dock.Right);footer.Children.Add(tools);footer.Children.Add(Button("Music",()=>{timerFocused=false;Render();}));stack.Children.Add(footer);Animate(144,398);return;
        }
        var heading=new Grid();heading.ColumnDefinitions.Add(new(){Width=new GridLength(76)});heading.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});heading.ColumnDefinitions.Add(new(){Width=new GridLength(30)});heading.Children.Add(Artwork(64));
        var titles=new StackPanel{VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,8,8,0)};titles.Children.Add(Text(media.Title,16,Brushes.White,FontWeights.Bold));titles.Children.Add(Text(media.Artist,14,Muted));Grid.SetColumn(titles,1);heading.Children.Add(titles);var wave=Wave();Grid.SetColumn(wave,2);heading.Children.Add(wave);stack.Children.Add(heading);
        var progressRow=new DockPanel{Margin=new Thickness(0,17,0,10)};elapsed=Text("0:00",11,Muted);elapsed.Width=40;remaining=Text("-0:00",11,Muted);remaining.Width=44;remaining.TextAlignment=TextAlignment.Right;DockPanel.SetDock(remaining,Dock.Right);progressRow.Children.Add(elapsed);progressRow.Children.Add(remaining);
        progress=new Slider{Minimum=0,Maximum=Math.Max(1,media.Duration),Value=media.Position,IsMoveToPointEnabled=true,VerticalAlignment=VerticalAlignment.Center,Height=20};progress.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>seeking=true));progress.PreviewMouseLeftButtonDown+=(_,_)=>seeking=true;progress.PreviewMouseLeftButtonUp+=async(_,_)=>{await media.Seek(progress.Value);seeking=false;};progress.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler(async(_,_)=>{if(progress!=null)await media.Seek(progress.Value);seeking=false;}));progressRow.Children.Add(progress);stack.Children.Add(progressRow);
        var controls=new UniformGrid{Columns=6};controls.Children.Add(Button("♡",async()=>{try{await spotify.SetLiked();Notify("Spotify library updated");}catch(Exception e){Notify(e.Message);}},"Like in Spotify",24));controls.Children.Add(Button("☷",async()=>await Queue(),"Spotify queue",22));controls.Children.Add(Button("⏮",async()=>await Skip("previous"),"Previous",23));controls.Children.Add(Button(media.Playing?"⏸":"▶",async()=>await media.Command("play"),"Play/Pause",25));controls.Children.Add(Button("⏭",async()=>await Skip("next"),"Next",23));controls.Children.Add(Button("⤨",async()=>await media.Command("shuffle"),"Shuffle",24));stack.Children.Add(controls);
        var toolbar=new DockPanel{Margin=new Thickness(0,8,0,0)};var settingsButton=Button("Settings",OpenSettings);DockPanel.SetDock(settingsButton,Dock.Right);toolbar.Children.Add(settingsButton);toolbar.Children.Add(Button(panel==""?"Tools":"Close tools",()=>{panel=panel==""?"Activities":"";Render();}));stack.Children.Add(toolbar);
        if(panel!="")stack.Children.Add(Tools());
        statusText=Text(DateTimeOffset.UtcNow<statusUntil?status:"",10,Muted);statusText.Margin=new Thickness(0,6,0,0);stack.Children.Add(statusText);
        Animate(panel==""?250:510,398);
    }
    Grid TimerCard()
    {
        var grid=new Grid();grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
        var controls=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};
        var pause=Button(countdown.Finished?"↻":countdown.Paused?"▶":"⏸",()=>{if(countdown.Finished)countdown.Start(countdown.Duration,DateTimeOffset.UtcNow);else countdown.Toggle(DateTimeOffset.UtcNow);Render();},"Pause, resume or restart",23);pause.Width=pause.Height=46;pause.Background=new SolidColorBrush(Color.FromRgb(66,42,6));controls.Children.Add(pause);
        var cancel=Button("×",()=>{countdown.Cancel();Render();},"Cancel timer",28);cancel.Width=cancel.Height=46;cancel.Margin=new Thickness(8,0,0,0);cancel.Background=Surface;controls.Children.Add(cancel);grid.Children.Add(controls);
        var labels=new StackPanel{HorizontalAlignment=HorizontalAlignment.Right};labels.Children.Add(Text(countdown.Finished?"Timer finished":countdown.Paused?"Paused":"Timer",12,Orange,FontWeights.SemiBold));timerText=Text(Countdown.Format(countdown.Remaining(DateTimeOffset.UtcNow)),32,Orange);labels.Children.Add(timerText);Grid.SetColumn(labels,1);grid.Children.Add(labels);return grid;
    }
    FrameworkElement Tools()
    {
        var content=new StackPanel{Margin=new Thickness(0,12,0,0)};
        var tabs=new UniformGrid{Columns=3};foreach(string name in new[]{"Activities","Files","Sound"})tabs.Children.Add(Button(name,()=>{panel=name;Render();}));content.Children.Add(tabs);
        if(panel=="Files") {
            if(!prefs.EnableShelf)content.Children.Add(Text("Enable File Shelf in Settings → Modules.",12,Muted));
            else {content.Children.Add(Text("Drop files here. Drag them into another app.",11,Muted));var list=new StackPanel();foreach(string file in files.ToArray()){var row=new DockPanel();var remove=Button("×",()=>{files.Remove(file);Render();},"Remove reference");DockPanel.SetDock(remove,Dock.Right);row.Children.Add(remove);var label=Text(System.IO.Path.GetFileName(file));label.MouseMove+=(_,e)=>{if(e.LeftButton==MouseButtonState.Pressed)DragDrop.DoDragDrop(label,new DataObject(DataFormats.FileDrop,new[]{file}),DragDropEffects.Copy);};row.Children.Add(label);list.Children.Add(row);}content.Children.Add(new ScrollViewer{Content=list,Height=135,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});}
        } else if(panel=="Sound") {
            if(prefs.EnableVolume){content.Children.Add(Text("Volume",12,Muted));var volume=new Slider{Minimum=0,Maximum=1,Value=audio.Volume,Margin=new Thickness(0,10,0,10)};volume.ValueChanged+=(_,_)=>audio.Volume=volume.Value;content.Children.Add(volume);}
            if(prefs.EnableBrightness){content.Children.Add(Text("Display brightness",12,Muted));var brightness=new Slider{Minimum=.05,Maximum=1,Value=.5,Margin=new Thickness(0,10,0,10)};brightness.PreviewMouseLeftButtonUp+=(_,_)=>audio.SetBrightness(brightness.Value);content.Children.Add(brightness);}
            content.Children.Add(Button("Windows sound settings",()=>Process.Start(new ProcessStartInfo("ms-settings:sound"){UseShellExecute=true})));
        } else if(panel=="Queue") {
            foreach(var title in queue.Take(5))content.Children.Add(Text(title,12,Muted));
        } else {
            if(prefs.EnableTimers){if(countdown.Active)content.Children.Add(TimerCard());else{var presets=new UniformGrid{Columns=4,Margin=new Thickness(0,10,0,8)};foreach(int minutes in new[]{1,5,15,25})presets.Children.Add(Button($"{minutes} min",()=>{countdown.Start(TimeSpan.FromMinutes(minutes),DateTimeOffset.UtcNow);panel="";timerFocused=true;Render();}));content.Children.Add(presets);}}
            if(prefs.EnableDownloads){var url=new TextBox{Height=30,Margin=new Thickness(0,8,0,8),ToolTip="HTTPS download URL"};content.Children.Add(url);content.Children.Add(Button(download==null?"Download…":"Cancel download",async()=>{if(download!=null)download.Cancel();else await Download(url.Text);}));}
            if(!prefs.EnableTimers && !prefs.EnableDownloads)content.Children.Add(Text("Enable optional tools in Settings → Modules.",12,Muted));
        }
        return content;
    }
    readonly List<string> queue=new();
    async Task Queue() { try { using var data=await spotify.Get("me/player/queue");queue.Clear();foreach(var item in data.RootElement.GetProperty("queue").EnumerateArray())queue.Add(item.GetProperty("name").GetString()??"Track");panel="Queue";Render(); }catch(Exception e){Notify(e.Message);} }
    async Task Skip(string direction) { if(!prefs.ReduceMotion)shell.BeginAnimation(OpacityProperty,new DoubleAnimation(.6,1,TimeSpan.FromMilliseconds(250)));await media.Command(direction); }
    async Task Download(string text)
    {
        if(!Uri.TryCreate(text,UriKind.Absolute,out var uri)||uri.Scheme!="https"||uri.UserInfo!=""){Notify("Enter an HTTPS download link.");return;}
        var dialog=new Microsoft.Win32.SaveFileDialog{FileName=System.IO.Path.GetFileName(uri.LocalPath),OverwritePrompt=true};if(dialog.ShowDialog()!=true)return;
        string temp=dialog.FileName+"."+Guid.NewGuid().ToString("N")+".partial";download=new();Render();
        try {using var response=await downloader.GetAsync(uri,HttpCompletionOption.ResponseHeadersRead,download.Token);response.EnsureSuccessStatusCode();await using(var input=await response.Content.ReadAsStreamAsync(download.Token))await using(var output=File.Create(temp))await input.CopyToAsync(output,download.Token);File.Move(temp,dialog.FileName,true);Notify("Download complete");if(prefs.EnableShelf && files.Count<20)files.Add(dialog.FileName);}
        catch(OperationCanceledException){Notify("Download cancelled");}catch(Exception e){Notify(e.Message);}finally{if(File.Exists(temp))File.Delete(temp);download.Dispose();download=null;Render();}
    }
    public void Dispose(){if(disposed)return;disposed=true;tick.Stop();hover.Stop();leave.Stop();waveTick.Stop();swipeEnd.Stop();if(source!=null){UnregisterHotKey(source.Handle,1);source.RemoveHook(Hook);}download?.Cancel();media.Dispose();audio.Dispose();spotify.Dispose();downloader.Dispose();}
}
