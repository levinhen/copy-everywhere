using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
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

    public async Task<ClipResponse?> SendFileAsync(string filePath, IProgress<(long sent, long total)>? progress = null, CancellationToken ct = default)
    {
        SetAuthHeader();

        var fileInfo = new FileInfo(filePath);
        var boundary = Guid.NewGuid().ToString();
        using var content = new MultipartFormDataContent(boundary);
        content.Add(new StringContent("file"), "type");

        var fileStream = new FileStream(filePath, FileMode.Open, FileAccess.Read);
        var streamContent = new ProgressStreamContent(fileStream, progress);
        streamContent.Headers.ContentType = new MediaTypeHeaderValue(GetMimeType(filePath));
        content.Add(streamContent, "content", fileInfo.Name);

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{BaseUrl}/api/v1/clips");
        request.Content = content;

        // Use a longer timeout for file uploads
        using var uploadClient = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        uploadClient.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", _config.AccessToken);

        var response = await uploadClient.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<ClipResponse>(json);
    }

    public async Task<UploadInitResponse?> InitChunkedUploadAsync(string filename, long sizeBytes, int chunkSize, CancellationToken ct = default)
    {
        SetAuthHeader();

        var body = JsonSerializer.Serialize(new { filename, size_bytes = sizeBytes, chunk_size = chunkSize });
        var content = new StringContent(body, Encoding.UTF8, "application/json");

        var response = await _httpClient.PostAsync($"{BaseUrl}/api/v1/uploads/init", content, ct);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<UploadInitResponse>(json);
    }

    public async Task UploadChunkAsync(string uploadId, int partNumber, byte[] data, CancellationToken ct = default)
    {
        SetAuthHeader();

        var content = new ByteArrayContent(data);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

        using var uploadClient = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        uploadClient.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", _config.AccessToken);

        var response = await uploadClient.PutAsync($"{BaseUrl}/api/v1/uploads/{uploadId}/parts/{partNumber}", content, ct);
        // 409 means chunk already uploaded (safe during resume)
        if (response.StatusCode != HttpStatusCode.Conflict)
            response.EnsureSuccessStatusCode();
    }

    public async Task<ClipResponse?> CompleteChunkedUploadAsync(string uploadId, CancellationToken ct = default)
    {
        SetAuthHeader();

        var response = await _httpClient.PostAsync($"{BaseUrl}/api/v1/uploads/{uploadId}/complete", null, ct);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<ClipResponse>(json);
    }

    public async Task<UploadStatusResponse?> GetUploadStatusAsync(string uploadId, CancellationToken ct = default)
    {
        SetAuthHeader();

        var response = await _httpClient.GetAsync($"{BaseUrl}/api/v1/uploads/{uploadId}/status", ct);
        if (response.StatusCode == HttpStatusCode.NotFound)
            return null;

        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<UploadStatusResponse>(json);
    }

    public async Task DownloadFileAsync(string clipId, string savePath, IProgress<(long received, long total)>? progress = null, CancellationToken ct = default)
    {
        using var downloadClient = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        downloadClient.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", _config.AccessToken);

        using var response = await downloadClient.GetAsync(
            $"{BaseUrl}/api/v1/clips/{clipId}/raw",
            HttpCompletionOption.ResponseHeadersRead,
            ct);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength ?? -1;
        using var contentStream = await response.Content.ReadAsStreamAsync(ct);
        using var fileStream = new FileStream(savePath, FileMode.Create, FileAccess.Write, FileShare.None, 8192);

        var buffer = new byte[8192];
        long totalRead = 0;
        int bytesRead;

        while ((bytesRead = await contentStream.ReadAsync(buffer, 0, buffer.Length, ct)) > 0)
        {
            await fileStream.WriteAsync(buffer, 0, bytesRead, ct);
            totalRead += bytesRead;
            progress?.Report((totalRead, totalBytes));
        }
    }

    private static string GetMimeType(string filePath)
    {
        var ext = Path.GetExtension(filePath).ToLowerInvariant();
        return ext switch
        {
            ".jpg" or ".jpeg" => "image/jpeg",
            ".png" => "image/png",
            ".gif" => "image/gif",
            ".bmp" => "image/bmp",
            ".webp" => "image/webp",
            ".pdf" => "application/pdf",
            ".txt" => "text/plain",
            ".zip" => "application/zip",
            _ => "application/octet-stream",
        };
    }

    public void Dispose()
    {
        _httpClient.Dispose();
    }
}

public class UploadInitResponse
{
    [JsonPropertyName("upload_id")]
    public string UploadId { get; set; } = "";

    [JsonPropertyName("chunk_count")]
    public int ChunkCount { get; set; }
}

public class UploadStatusResponse
{
    [JsonPropertyName("upload_id")]
    public string UploadId { get; set; } = "";

    [JsonPropertyName("received_parts")]
    public List<int> ReceivedParts { get; set; } = new();

    [JsonPropertyName("total_parts")]
    public int TotalParts { get; set; }

    [JsonPropertyName("status")]
    public string Status { get; set; } = "";
}

public class ProgressStreamContent : HttpContent
{
    private readonly Stream _stream;
    private readonly IProgress<(long sent, long total)>? _progress;

    public ProgressStreamContent(Stream stream, IProgress<(long sent, long total)>? progress)
    {
        _stream = stream;
        _progress = progress;
    }

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
    {
        var buffer = new byte[8192];
        long totalSent = 0;
        var totalLength = _stream.Length;
        int bytesRead;

        while ((bytesRead = await _stream.ReadAsync(buffer, 0, buffer.Length)) > 0)
        {
            await stream.WriteAsync(buffer, 0, bytesRead);
            totalSent += bytesRead;
            _progress?.Report((totalSent, totalLength));
        }
    }

    protected override bool TryComputeLength(out long length)
    {
        length = _stream.Length;
        return true;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _stream.Dispose();
        base.Dispose(disposing);
    }
}
