using System;
using System.IO;
using System.Text.Json;

namespace Undertone;
public sealed class Preferences
{
    public bool AlwaysShow { get; set; } = true;
    public bool NotchStyle { get; set; }
    public bool Outline { get; set; }
    public bool ReverseSwipe { get; set; }
    public bool ReduceMotion { get; set; }
    public bool EnableTimers { get; set; }
    public bool EnableShelf { get; set; }
    public bool EnableAudio { get; set; }
    public bool EnableVolume { get; set; }
    public bool EnableBrightness { get; set; }
    public bool EnableDownloads { get; set; }
    public bool PreferSpotify { get; set; } = true;
    public double Gap { get; set; } = 12;
    public double AnimationStrength { get; set; } = 1;
    public string Display { get; set; } = "";
    public string SpotifyClientId { get; set; } = "";
    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Undertone");
    public static Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(DirectoryPath, "settings.json"))) ?? new(); }
        catch { return new(); }
    }
    public void Save() { Directory.CreateDirectory(DirectoryPath); File.WriteAllText(Path.Combine(DirectoryPath, "settings.json"), JsonSerializer.Serialize(this)); }
}
public sealed class Countdown
{
    public DateTimeOffset? Deadline { get; private set; }
    public TimeSpan PausedTime { get; private set; }
    public TimeSpan Duration { get; private set; }
    public bool Finished { get; private set; }
    public bool Paused => Deadline == null && PausedTime > TimeSpan.Zero;
    public bool Active => Deadline != null || Paused || Finished;
    public TimeSpan Remaining(DateTimeOffset now) => Deadline is { } end ? (end > now ? end - now : TimeSpan.Zero) : PausedTime;
    public void Start(TimeSpan duration, DateTimeOffset now) { Duration = duration; Deadline = now + duration; PausedTime = TimeSpan.Zero; Finished = false; }
    public void Toggle(DateTimeOffset now) { if (Paused) { Deadline = now + PausedTime; PausedTime = TimeSpan.Zero; } else if (Deadline != null) { PausedTime = Remaining(now); Deadline = null; Finished = PausedTime <= TimeSpan.Zero; } }
    public bool Tick(DateTimeOffset now) { if (Deadline is not { } end || now < end) return false; Deadline = null; Finished = true; return true; }
    public void Cancel() { Deadline = null; PausedTime = TimeSpan.Zero; Finished = false; }
    public static string Format(TimeSpan duration) { var s = Math.Max(0, (int)Math.Ceiling(duration.TotalSeconds)); return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}"; }
}
