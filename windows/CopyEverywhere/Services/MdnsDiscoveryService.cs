using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Zeroconf;

namespace CopyEverywhere.Services;

public class DiscoveredServer
{
    public string Id { get; set; } = ""; // Display identity only. Persistent selection must use ServerId.
    public string? ServerId { get; set; }
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; }
    public bool AuthRequired { get; set; }
    public string Version { get; set; } = "";
}

public class MdnsDiscoveryService : INotifyPropertyChanged, IDisposable
{
    private const string ServiceType = "_copyeverywhere._tcp.local.";
    private const int ScanIntervalMs = 5000;

    private List<DiscoveredServer> _discoveredServers = new();
    private bool _isSearching;
    private string? _lastErrorMessage;
    private CancellationTokenSource? _cts;
    private Task? _scanTask;

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? ServersChanged;

    public List<DiscoveredServer> DiscoveredServers
    {
        get => _discoveredServers;
        private set
        {
            _discoveredServers = value;
            OnPropertyChanged();
            ServersChanged?.Invoke();
        }
    }

    public bool IsSearching
    {
        get => _isSearching;
        private set { _isSearching = value; OnPropertyChanged(); }
    }

    public string? LastErrorMessage
    {
        get => _lastErrorMessage;
        private set { _lastErrorMessage = value; OnPropertyChanged(); }
    }

    public void StartBrowsing()
    {
        StopBrowsing();
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        _scanTask = Task.Run(async () => await ScanLoop(ct), ct);
        IsSearching = true;
        LastErrorMessage = null;
    }

    public void StopBrowsing()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;
        _scanTask = null;
        IsSearching = false;
        LastErrorMessage = null;
    }

    private async Task ScanLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await ScanOnce(ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                // Scan errors are non-fatal — retry on next interval
                System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                {
                    LastErrorMessage = ex.Message;
                });
            }

            try
            {
                await Task.Delay(ScanIntervalMs, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task ScanOnce(CancellationToken ct)
    {
        var results = await ZeroconfResolver.ResolveAsync(ServiceType,
            scanTime: TimeSpan.FromSeconds(2),
            cancellationToken: ct);

        var servers = new List<DiscoveredServer>();

        foreach (var host in results)
        {
            if (ct.IsCancellationRequested) break;

            foreach (var service in host.Services.Values)
            {
                var authRequired = false;
                var version = "";
                string? serverId = null;

                if (service.Properties != null)
                {
                    foreach (var propSet in service.Properties)
                    {
                        if (propSet.TryGetValue("auth", out var authVal))
                            authRequired = string.Equals(authVal, "true", StringComparison.OrdinalIgnoreCase);
                        if (propSet.TryGetValue("version", out var versionVal))
                            version = versionVal ?? "";
                        if (propSet.TryGetValue("server_id", out var serverIdVal))
                            serverId = serverIdVal;
                    }
                }

                var ip = host.IPAddresses.FirstOrDefault() ?? host.DisplayName;
                var port = service.Port;

                servers.Add(new DiscoveredServer
                {
                    Id = $"{ip}:{port}",
                    ServerId = serverId,
                    Name = host.DisplayName,
                    Host = ip,
                    Port = port,
                    AuthRequired = authRequired,
                    Version = version,
                });
            }
        }

        // Update on UI thread
        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
        {
            LastErrorMessage = null;
            DiscoveredServers = servers;
        });
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public void Dispose()
    {
        StopBrowsing();
    }
}
