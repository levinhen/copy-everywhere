using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.Data.Sqlite;

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
        _dbPath = Path.Combine(dir, "history.db");
        InitializeDatabase();
        Load();
    }

    private void InitializeDatabase()
    {
        using var connection = new SqliteConnection($"Data Source={_dbPath}");
        connection.Open();

        using var cmd = connection.CreateCommand();
        cmd.CommandText = @"
            CREATE TABLE IF NOT EXISTS history (
                clip_id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                filename TEXT,
                timestamp TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'success'
            )";
        cmd.ExecuteNonQuery();
    }

    public void AddRecord(HistoryRecord record)
    {
        using var connection = new SqliteConnection($"Data Source={_dbPath}");
        connection.Open();

        using var cmd = connection.CreateCommand();
        cmd.CommandText = @"
            INSERT OR REPLACE INTO history (clip_id, type, filename, timestamp, expires_at, status)
            VALUES (@clipId, @type, @filename, @timestamp, @expiresAt, @status)";
        cmd.Parameters.AddWithValue("@clipId", record.ClipId);
        cmd.Parameters.AddWithValue("@type", record.Type);
        cmd.Parameters.AddWithValue("@filename", (object?)record.Filename ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@timestamp", record.Timestamp.ToString("O"));
        cmd.Parameters.AddWithValue("@expiresAt", record.ExpiresAt.ToString("O"));
        cmd.Parameters.AddWithValue("@status", record.Status);
        cmd.ExecuteNonQuery();

        Load();
    }

    public void DeleteRecord(string clipId)
    {
        using var connection = new SqliteConnection($"Data Source={_dbPath}");
        connection.Open();

        using var cmd = connection.CreateCommand();
        cmd.CommandText = "DELETE FROM history WHERE clip_id = @clipId";
        cmd.Parameters.AddWithValue("@clipId", clipId);
        cmd.ExecuteNonQuery();

        Load();
    }

    private void Load()
    {
        var records = new List<HistoryRecord>();

        using var connection = new SqliteConnection($"Data Source={_dbPath}");
        connection.Open();

        using var cmd = connection.CreateCommand();
        cmd.CommandText = "SELECT clip_id, type, filename, timestamp, expires_at, status FROM history ORDER BY timestamp DESC";

        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            records.Add(new HistoryRecord
            {
                ClipId = reader.GetString(0),
                Type = reader.GetString(1),
                Filename = reader.IsDBNull(2) ? null : reader.GetString(2),
                Timestamp = DateTime.Parse(reader.GetString(3)),
                ExpiresAt = DateTime.Parse(reader.GetString(4)),
                Status = reader.GetString(5),
            });
        }

        _records = records;
    }
}
