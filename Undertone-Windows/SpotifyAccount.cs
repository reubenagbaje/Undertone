using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Diagnostics;

namespace Undertone;
public sealed class SpotifyAccount : IDisposable
{
    readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(20) };
    readonly SemaphoreSlim refreshLock = new(1,1);
    readonly Preferences preferences;
    string? access, refresh;
    DateTimeOffset expiry;
    HttpListener? listener;
    const string Redirect = "http://127.0.0.1:43821/callback/";
    public bool Connected => refresh != null;
    string TokenPath => Path.Combine(Preferences.DirectoryPath, "spotify-token.bin");
    public SpotifyAccount(Preferences preferences) {
        this.preferences = preferences;
        try { refresh = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(TokenPath), null, DataProtectionScope.CurrentUser)); } catch { }
    }
    static string Base64(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+','-').Replace('/','_');
    public async Task Connect()
    {
        if (string.IsNullOrWhiteSpace(preferences.SpotifyClientId)) throw new InvalidOperationException("Enter your Spotify developer Client ID first.");
        if (listener != null) throw new InvalidOperationException("A connection is already in progress.");
        string verifier = Base64(RandomNumberGenerator.GetBytes(32)), state = Base64(RandomNumberGenerator.GetBytes(24));
        var challenge = Base64(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        using var active = new HttpListener(); listener = active;
        try {
            active.Prefixes.Add(Redirect); active.Start();
            string url = "https://accounts.spotify.com/authorize?response_type=code&client_id=" + Uri.EscapeDataString(preferences.SpotifyClientId.Trim()) + "&redirect_uri=" + Uri.EscapeDataString(Redirect) + "&code_challenge_method=S256&code_challenge=" + challenge + "&state=" + state + "&scope=" + Uri.EscapeDataString("user-library-read user-library-modify user-read-playback-state user-modify-playback-state");
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            var context = await active.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(3));
            bool valid = context.Request.QueryString["state"] == state && !string.IsNullOrEmpty(context.Request.QueryString["code"]);
            var bytes = Encoding.UTF8.GetBytes(valid ? "You can return to Undertone." : "Spotify connection was not accepted."); context.Response.StatusCode = valid ? 200 : 400; await context.Response.OutputStream.WriteAsync(bytes); context.Response.Close();
            if (!valid) throw new InvalidOperationException("Spotify authentication failed. Please try again.");
            await Token(new Dictionary<string,string> { ["grant_type"]="authorization_code", ["code"]=context.Request.QueryString["code"]!, ["redirect_uri"]=Redirect, ["code_verifier"]=verifier, ["client_id"]=preferences.SpotifyClientId.Trim() });
        } finally { active.Stop(); listener = null; }
    }
    async Task Token(Dictionary<string,string> body)
    {
        using var response = await http.PostAsync("https://accounts.spotify.com/api/token", new FormUrlEncodedContent(body)); response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        access = json.RootElement.GetProperty("access_token").GetString(); expiry = DateTimeOffset.UtcNow.AddSeconds(json.RootElement.GetProperty("expires_in").GetInt32() - 60);
        if (json.RootElement.TryGetProperty("refresh_token", out var token)) refresh = token.GetString();
        Directory.CreateDirectory(Preferences.DirectoryPath); File.WriteAllBytes(TokenPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(refresh!), null, DataProtectionScope.CurrentUser));
    }
    async Task<string> Access()
    {
        await refreshLock.WaitAsync();
        try {
            if (access == null || DateTimeOffset.UtcNow >= expiry) {
                if (refresh == null) throw new InvalidOperationException("Connect Spotify in Settings first.");
                await Token(new Dictionary<string,string> { ["grant_type"]="refresh_token", ["refresh_token"]=refresh, ["client_id"]=preferences.SpotifyClientId.Trim() });
            }
            return access!;
        } finally { refreshLock.Release(); }
    }
    public async Task<JsonDocument> Get(string path)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.spotify.com/v1/" + path); request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await Access());
        using var response = await http.SendAsync(request); response.EnsureSuccessStatusCode(); return JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    }
    public async Task SetLiked()
    {
        using var current = await Get("me/player");
        if (!current.RootElement.TryGetProperty("item", out var item) || item.ValueKind == JsonValueKind.Null) throw new InvalidOperationException("No Spotify track is playing.");
        string id = item.GetProperty("id").GetString()!;
        using var existing = await Get("me/tracks/contains?ids=" + Uri.EscapeDataString(id));
        bool liked = existing.RootElement[0].GetBoolean();
        using var request = new HttpRequestMessage(liked ? HttpMethod.Delete : HttpMethod.Put, "https://api.spotify.com/v1/me/tracks?ids=" + Uri.EscapeDataString(id)); request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await Access());
        using var response = await http.SendAsync(request); response.EnsureSuccessStatusCode();
    }
    public void Disconnect() { access = refresh = null; if (File.Exists(TokenPath)) File.Delete(TokenPath); }
    public void Dispose() { listener?.Close(); http.Dispose(); }
}
