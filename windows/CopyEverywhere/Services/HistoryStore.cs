using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace CopyEverywhere.Services;

public class HistoryRecord
{
    public string ClipId { get; set; } = "";
    public string Type { get; set; } = ""; // text, image, file
    public string? Filename { get; set; }
    public DateTime Timestamp { get; set; }
    public DateTime ExpiresAt { get; set; }
    public string Status { get; set; } = "success"; // success, failed

    public bool IsExpired => DateTime.UtcNow > ExpiresAt;

    public string TypeIcon => Type switch
    {
        "text" => "\U0001F4DD", // memo emoji
        "image" => "\U0001F5BC", // framed picture
        _ => "\U0001F4CE",      // paperclip (file)
    };

    public string DisplayLabel
    {
        get
        {
            if (Status == "failed") return "Upload Failed";
            if (IsExpired) return "Expired";
            return "Active";
        }
    }
}

public class HistoryStore
{
    private readonly string _dbPath;
    private List<HistoryRecord> _records = new();

    public IReadOnlyList<HistoryRecord> Records => _records;

    public HistoryStore()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var dir = Path.Combine(appData, "CopyEverywhere");
        Directory.CreateDirectory(dir);
        _dbPath = Path.Combine(dir, "history.json");
        Load();
    }

    public void AddRecord(HistoryRecord record)
    {
        // Remove existing record with same ClipId if any
        _records.RemoveAll(r => r.ClipId == record.ClipId);
        _records.Insert(0, record);
        Save();
    }

    public void DeleteRecord(string clipId)
    {
        _records.RemoveAll(r => r.ClipId == clipId);
        Save();
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_dbPath))
            {
                var json = File.ReadAllText(_dbPath);
                _records = JsonSerializer.Deserialize<List<HistoryRecord>>(json) ?? new();
            }
        }
        catch
        {
            _records = new();
        }
    }

    private void Save()
    {
        try
        {
            var json = JsonSerializer.Serialize(_records, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_dbPath, json);
        }
        catch
        {
            // Silently fail on write errors
        }
    }
}
