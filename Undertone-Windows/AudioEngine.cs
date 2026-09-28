using System;
using System.Linq;
using System.Management;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Dsp;

namespace Undertone;
public sealed class AudioEngine : IDisposable
{
    WasapiLoopbackCapture? capture;
    readonly MMDeviceEnumerator devices = new();
    readonly Complex[] fft = new Complex[1024];
    readonly double[] levels = new double[4];
    readonly object sync = new();
    int cursor;
    long lastData;
    public event Action<string>? Error;
    public double[] Levels { get { lock (sync) return levels.Select(x => x * Math.Exp(-Math.Max(0, Environment.TickCount64 - lastData - 100) / 180.0)).ToArray(); } }
    public void Start()
    {
        Stop();
        try { capture = new WasapiLoopbackCapture(); capture.DataAvailable += Data; capture.RecordingStopped += Stopped; capture.StartRecording(); }
        catch (Exception e) { Error?.Invoke("Audio capture: " + e.Message); Stop(); }
    }
    void Stopped(object? sender, NAudio.Wave.StoppedEventArgs args) { if (args.Exception != null) App.UI(() => Error?.Invoke("Audio device changed. Toggle the waveform off and on to reconnect.")); }
    void Data(object? sender, WaveInEventArgs args)
    {
        var format = capture?.WaveFormat; if (format == null) return;
        int bytes = format.BitsPerSample / 8, stride = bytes * format.Channels;
        for (int i = 0; i + stride <= args.BytesRecorded; i += stride) {
            double sample = 0;
            for (int channel = 0; channel < format.Channels; channel++) {
                int offset = i + channel * bytes;
                sample += bytes == 4 ? BitConverter.ToSingle(args.Buffer, offset) : bytes == 2 ? BitConverter.ToInt16(args.Buffer, offset) / 32768.0 : 0;
            }
            if (!double.IsFinite(sample)) sample = 0;
            fft[cursor].X = (float)(sample / format.Channels * FastFourierTransform.HannWindow(cursor, fft.Length)); fft[cursor].Y = 0;
            if (++cursor != fft.Length) continue;
            cursor = 0; FastFourierTransform.FFT(true, 10, fft);
            int[] limits = { 1, 6, 24, 90, 256 };
            lastData = Environment.TickCount64;
            lock (sync) for (int band = 0; band < 4; band++) {
                double peak = 0;
                for (int bin = limits[band]; bin < limits[band + 1]; bin++) peak = Math.Max(peak, Math.Sqrt(fft[bin].X * fft[bin].X + fft[bin].Y * fft[bin].Y));
                levels[band] = Math.Clamp(Math.Sqrt(peak) * 4, 0, 1);
            }
        }
    }
    public double Volume
    {
        get { try { using var d = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia); return d.AudioEndpointVolume.MasterVolumeLevelScalar; } catch { return 0; } }
        set { try { using var d = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia); d.AudioEndpointVolume.MasterVolumeLevelScalar = (float)Math.Clamp(value, 0, 1); } catch (Exception e) { Error?.Invoke(e.Message); } }
    }
    public string[] Outputs() { try { var collection = devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active); return collection.Select(d => d.FriendlyName).ToArray(); } catch { return Array.Empty<string>(); } }
    public void SetBrightness(double value)
    {
        try {
            using var query = new ManagementObjectSearcher("root\\WMI", "SELECT * FROM WmiMonitorBrightnessMethods");
            using var results = query.Get();
            bool changed = false;
            foreach (ManagementObject display in results) { using (display) display.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, (byte)Math.Clamp(value * 100, 5, 100) }); changed = true; }
            if (!changed) Error?.Invoke("Brightness is unavailable for this display. Use its hardware controls.");
        } catch (Exception e) { Error?.Invoke("Brightness: " + e.Message); }
    }
    public void Stop() { var old = capture; capture = null; if (old != null) { old.DataAvailable -= Data; old.RecordingStopped -= Stopped; old.StopRecording(); old.Dispose(); } lock (sync) Array.Clear(levels); cursor = 0; }
    public void Dispose() { Stop(); devices.Dispose(); }
}
