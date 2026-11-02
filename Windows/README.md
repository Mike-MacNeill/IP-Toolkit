# IP Toolkit for Windows

This is a Windows-native WPF implementation. The original macOS project remains unchanged.

## Requirements

- Windows 10 or 11
- .NET 10 SDK and Inno Setup 6 to build the installer
- The self-contained installer does not require the .NET runtime to be installed
- nmap from [nmap.org](https://nmap.org) for port scans; add `nmap.exe` to `PATH` or install it in `C:\Program Files\Nmap`

## Run

From the repository root:

```powershell
dotnet run --project Windows/IPToolkit.Windows/IPToolkit.Windows.csproj
```

To publish the self-contained Windows x64 application and create its installer:

```powershell
.\Windows\build.ps1
```

For Windows on ARM, run `.\\Windows\\build.ps1 -RuntimeIdentifier win-arm64` in PowerShell.
The published files are placed under `Windows/dist/<runtime>`, and the installer is written to `Windows/dist/installer/IPToolkit-Setup-<runtime>.exe`.

## Tools

- **IP Lookup** queries the IANA RDAP bootstrap and registry, then requests geolocation from ipinfo.io with ipwho.is as a fallback. Maps open in the default browser. Public-IP services receive the queried address.
- **Subnet Calculator** handles IPv4/IPv6 addresses, CIDR prefixes, IPv4 netmasks, subnet details, and subnet splitting offline.
- **Reputation** checks AbuseIPDB. The API key is stored in Windows Credential Manager and sent only in the HTTPS request header.
- **Network** runs Windows `ping.exe` or `tracert.exe`; port scans use the optional nmap installation. Only scan systems and networks you are authorized to test.
- **Speed Test** measures HTTPS latency and throughput using Cloudflare. A completed test transfers approximately 36 MB.

**My IP** checks ipify and icanhazip for public IPv4/IPv6 addresses. **Open at login** uses the current user's Windows Run registry key. Minimizing the window hides it to the system tray; open it again from the tray icon or choose Exit to close it.