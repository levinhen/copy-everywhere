using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace CopyEverywhere.Services;

public class HealthResponse
{
    public string Version { get; set; } = "";
    public string Uptime { get; set; } = "";
}

public class TestConnectionResult
{
    public bool Success { get; set; }
    public string Message { get; set; } = "";
    public long LatencyMs { get; set; }
}

public class ClipResponse
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    [JsonPropertyName("filename")]
    public string? Filename { get; set; }

    [JsonPropertyName("size_bytes")]
    public long SizeBytes { get; set; }

    [JsonPropertyName("created_at")]
    public DateTime CreatedAt { get; set; }

    [JsonPropertyName("expires_at")]
    public DateTime ExpiresAt { get; set; }
}

public class ApiClient : IDisposable
{
    private readonly HttpClient _httpClient;
    private readonly ConfigStore _config;

    public ApiClient(ConfigStore config)
    {
        _config = config;
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(10),
        };
    }

    private string BaseUrl => _config.HostUrl.TrimEnd('/');

    private void SetAuthHeader()
    {
        _httpClient.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", _config.AccessToken);
    }

    public async Task<TestConnectionResult> TestConnectionAsync(CancellationToken ct = default)
    {
        try
        {
            var sw = Stopwatch.StartNew();
            var response = await _httpClient.GetAsync($"{BaseUrl}/health", ct);
            sw.Stop();

            if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                // Health endpoint doesn't require auth, but check with auth header too
                SetAuthHeader();
                var authResponse = await _httpClient.GetAsync($"{BaseUrl}/api/v1/clips/latest", ct);
                if (authResponse.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                {
                    return new TestConnectionResult
                    {
                        Success = false,
                        Message = "Authentication failed (401) — check your access token",
                    };
                }
            }

            if (!response.IsSuccessStatusCode)
            {
                return new TestConnectionResult
                {
                    Success = false,
                    Message = $"Server returned HTTP {(int)response.StatusCode}",
                };
            }

            var json = await response.Content.ReadAsStringAsync(ct);
            var health = JsonSerializer.Deserialize<HealthResponse>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            });

            // Verify auth works by calling an authed endpoint
            SetAuthHeader();
            var authCheck = await _httpClient.GetAsync($"{BaseUrl}/api/v1/clips/latest", ct);
            if (authCheck.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                return new TestConnectionResult
                {
                    Success = false,
                    Message = "Authentication failed (401) — check your access token",
                };
            }

            return new TestConnectionResult
            {
                Success = true,
                Message = $"Connected — v{health?.Version ?? "?"}, latency {sw.ElapsedMilliseconds}ms",
                LatencyMs = sw.ElapsedMilliseconds,
            };
        }
        catch (TaskCanceledException)
        {
            return new TestConnectionResult
            {
                Success = false,
                Message = "Connection timed out — check the server URL and ensure the server is running",
            };
        }
        catch (HttpRequestException ex) when (ex.InnerException is System.Net.Sockets.SocketException)
        {
            return new TestConnectionResult
            {
                Success = false,
                Message = "Connection refused — check the server URL and ensure the server is running",
            };
        }
        catch (HttpRequestException ex)
        {
            return new TestConnectionResult
            {
                Success = false,
                Message = $"Connection error: {ex.Message}",
            };
        }
        catch (Exception ex)
        {
            return new TestConnectionResult
            {
                Success = false,
                Message = $"Unexpected error: {ex.Message}",
            };
        }
    }

    public async Task<ClipResponse?> SendTextClipAsync(string text, CancellationToken ct = default)
    {
        SetAuthHeader();

        var boundary = Guid.NewGuid().ToString();
        using var content = new MultipartFormDataContent(boundary);
        content.Add(new StringContent("text"), "type");
        var fileContent = new ByteArrayContent(Encoding.UTF8.GetBytes(text));
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("text/plain");
        content.Add(fileContent, "content", "clipboard.txt");

        var response = await _httpClient.PostAsync($"{BaseUrl}/api/v1/clips", content, ct);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<ClipResponse>(json);
    }

    public async Task<ClipResponse?> GetLatestClipAsync(CancellationToken ct = default)
    {
        SetAuthHeader();

        var response = await _httpClient.GetAsync($"{BaseUrl}/api/v1/clips/latest", ct);
        if (response.StatusCode == HttpStatusCode.NotFound)
            return null;

        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<ClipResponse>(json);
    }

    public async Task<ClipResponse?> GetClipMetadataAsync(string clipId, CancellationToken ct = default)
    {
        SetAuthHeader();

        var response = await _httpClient.GetAsync($"{BaseUrl}/api/v1/clips/{clipId}", ct);
        if (response.StatusCode == HttpStatusCode.NotFound)
            return null;

        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<ClipResponse>(json);
    }

    public async Task<string?> GetClipRawTextAsync(string clipId, CancellationToken ct = default)
    {
        SetAuthHeader();

        var response = await _httpClient.GetAsync($"{BaseUrl}/api/v1/clips/{clipId}/raw", ct);
        if (response.StatusCode == HttpStatusCode.NotFound)
            return null;

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync(ct);
    }

    public void Dispose()
    {
        _httpClient.Dispose();
    }
}
