using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using CredentialManagement;

namespace CopyEverywhere.Services;

public class ConfigStore : INotifyPropertyChanged
{
    private const string CredentialTargetHost = "CopyEverywhere_HostURL";
    private const string CredentialTargetToken = "CopyEverywhere_AccessToken";

    private string _hostUrl = "";
    private string _accessToken = "";

    public event PropertyChangedEventHandler? PropertyChanged;

    public string HostUrl
    {
        get => _hostUrl;
        set { _hostUrl = value; OnPropertyChanged(); }
    }

    public string AccessToken
    {
        get => _accessToken;
        set { _accessToken = value; OnPropertyChanged(); }
    }

    public bool IsConfigured => !string.IsNullOrWhiteSpace(HostUrl) && !string.IsNullOrWhiteSpace(AccessToken);

    public ConfigStore()
    {
        Load();
    }

    public void Load()
    {
        HostUrl = ReadCredential(CredentialTargetHost) ?? "";
        AccessToken = ReadCredential(CredentialTargetToken) ?? "";
    }

    public void Save()
    {
        WriteCredential(CredentialTargetHost, HostUrl);
        WriteCredential(CredentialTargetToken, AccessToken);
    }

    private static string? ReadCredential(string target)
    {
        var cred = new Credential { Target = target };
        if (cred.Load())
        {
            return cred.Password;
        }
        return null;
    }

    private static void WriteCredential(string target, string value)
    {
        var cred = new Credential
        {
            Target = target,
            Password = value,
            PersistanceType = PersistanceType.LocalComputer,
            Type = CredentialType.Generic,
        };
        cred.Save();
    }

    public static void DeleteCredentials()
    {
        new Credential { Target = CredentialTargetHost }.Delete();
        new Credential { Target = CredentialTargetToken }.Delete();
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
