using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace Undertone;
public sealed class MediaEngine : IDisposable
{
    readonly Preferences preferences;
    GlobalSystemMediaTransportControlsSessionManager? manager;
    GlobalSystemMediaTransportControlsSession? session;
    int generation;
    public string Title { get; private set; } = "Nothing playing";
    public string Artist { get; private set; } = "Open Spotify to begin";
    public string Source { get; private set; } = "";
    public BitmapSource? Artwork { get; private set; }
    public bool Playing { get; private set; }
    public bool Connected => session != null;
    public double Duration { get; private set; }
    double position;
    DateTimeOffset sampled;
    public double Position => Math.Clamp(position + (Playing ? (DateTimeOffset.UtcNow - sampled).TotalSeconds : 0), 0, Math.Max(0, Duration));
    public event Action? Changed;
    public event Action<string>? Error;
    public MediaEngine(Preferences preferences) { this.preferences = preferences; }
    public async Task Start()
    {
        try { manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync(); manager.SessionsChanged += SessionsChanged; manager.CurrentSessionChanged += SessionsChanged; Select(); }
        catch (Exception e) { Error?.Invoke("Media connection: " + e.Message); }
    }
    void SessionsChanged(GlobalSystemMediaTransportControlsSessionManager sender, object args) => App.UI(Select);
    public void Select()
    {
        var next = preferences.PreferSpotify ? manager?.GetSessions().FirstOrDefault(s => s.SourceAppUserModelId.Contains("Spotify", StringComparison.OrdinalIgnoreCase)) : null;
        next ??= manager?.GetCurrentSession();
        if (ReferenceEquals(next, session)) return;
        Detach(); session = next; generation++;
        if (session != null) { session.MediaPropertiesChanged += MetadataChanged; session.PlaybackInfoChanged += PlaybackChanged; session.TimelinePropertiesChanged += TimelineChanged; Source = session.SourceAppUserModelId; _ = Read(); }
        else { Title = "Nothing playing"; Artist = "Open Spotify to begin"; Source = ""; Artwork = null; Playing = false; Duration = 0; position = 0; Changed?.Invoke(); }
    }
    void MetadataChanged(GlobalSystemMediaTransportControlsSession sender, MediaPropertiesChangedEventArgs args) => App.UI(() => { if (ReferenceEquals(sender, session)) _ = Read(); });
    void PlaybackChanged(GlobalSystemMediaTransportControlsSession sender, PlaybackInfoChangedEventArgs args) => App.UI(() => { if (ReferenceEquals(sender, session)) { ReadTimeline(); Changed?.Invoke(); } });
    void TimelineChanged(GlobalSystemMediaTransportControlsSession sender, TimelinePropertiesChangedEventArgs args) => App.UI(() => { if (ReferenceEquals(sender, session)) { ReadTimeline(); Changed?.Invoke(); } });
    async Task Read()
    {
        var active = session; int stamp = generation;
        if (active == null) return;
        try {
            var properties = await active.TryGetMediaPropertiesAsync();
            BitmapImage? image = null;
            if (properties.Thumbnail != null) {
                using var stream = await properties.Thumbnail.OpenReadAsync();
                if (stream.Size > 0 && stream.Size < 16 * 1024 * 1024) {
                    using var reader = new DataReader(stream); await reader.LoadAsync((uint)stream.Size);
                    var bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes);
                    using var memory = new System.IO.MemoryStream(bytes); image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.DecodePixelWidth = 512; image.StreamSource = memory; image.EndInit(); image.Freeze();
                }
            }
            if (stamp != generation) return;
            Title = string.IsNullOrWhiteSpace(properties.Title) ? "Unknown track" : properties.Title; Artist = properties.Artist; Artwork = image; ReadTimeline(); Changed?.Invoke();
        } catch (Exception e) { if (stamp == generation) Error?.Invoke("Track information: " + e.Message); }
    }
    void ReadTimeline()
    {
        if (session == null) return;
        try { var timeline = session.GetTimelineProperties(); Duration = Math.Max(0, timeline.EndTime.TotalSeconds); position = Math.Max(0, timeline.Position.TotalSeconds); sampled = DateTimeOffset.UtcNow; Playing = session.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing; }
        catch (Exception e) { Error?.Invoke(e.Message); }
    }
    public async Task Command(string command)
    {
        var active = session; if (active == null) return;
        try {
            bool ok = command switch {
                "play" => await active.TryTogglePlayPauseAsync(),
                "next" => await active.TrySkipNextAsync(),
                "previous" => Position > 3 ? await active.TryChangePlaybackPositionAsync(0) : await active.TrySkipPreviousAsync(),
                "shuffle" => await active.TryChangeShuffleActiveAsync(!(active.GetPlaybackInfo().IsShuffleActive ?? false)),
                _ => false
            };
            if (!ok) Error?.Invoke("This player does not support that control.");
        } catch (Exception e) { Error?.Invoke(e.Message); }
    }
    public async Task Seek(double seconds)
    {
        var active = session; if (active == null || Duration <= 0) return;
        position = Math.Clamp(seconds, 0, Duration); sampled = DateTimeOffset.UtcNow;
        try { if (!await active.TryChangePlaybackPositionAsync(TimeSpan.FromSeconds(position).Ticks)) Error?.Invoke("Seeking is unavailable for this media."); }
        catch (Exception e) { Error?.Invoke(e.Message); }
    }
    void Detach() { if (session == null) return; session.MediaPropertiesChanged -= MetadataChanged; session.PlaybackInfoChanged -= PlaybackChanged; session.TimelinePropertiesChanged -= TimelineChanged; }
    public void Dispose() { generation++; Detach(); if (manager != null) { manager.SessionsChanged -= SessionsChanged; manager.CurrentSessionChanged -= SessionsChanged; } }
}
