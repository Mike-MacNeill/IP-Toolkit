using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace IPToolkit.Windows;

internal static class ToolkitServices
{
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = true })
    {
        Timeout = TimeSpan.FromSeconds(30)
    };
    private static readonly HttpClient NoRedirectHttp = new(new HttpClientHandler { AllowAutoRedirect = false })
    {
        Timeout = TimeSpan.FromSeconds(30)
    };

    public static async Task<string> GetMyIpAsync(CancellationToken cancellationToken)
    {
        var addresses = new List<string>();
        var foundV4 = false;
        var foundV6 = false;
        foreach (var (url, v6) in new[]
                 {
                     ("https://api.ipify.org", false), ("https://ipv4.icanhazip.com", false),
                     ("https://api6.ipify.org", true), ("https://ipv6.icanhazip.com", true)
                 })
        {
            if (v6 ? foundV6 : foundV4) continue;
            try
            {
                using var response = await Http.GetAsync(url, cancellationToken);
                if (!response.IsSuccessStatusCode) continue;
                var text = await response.Content.ReadAsStringAsync(cancellationToken);
                if (!NetAddress.TryParse(text, out var address) || address.IsV6 != v6) continue;
                var line = $"IPv{(v6 ? 6 : 4)}: {address}";
                addresses.Add(line);
                if (v6) foundV6 = true;
                else foundV4 = true;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested) { }
        }

        if (addresses.Count == 0) throw new InvalidOperationException("Could not determine your public IP address.");
        return string.Join(Environment.NewLine, addresses);
    }

    public static async Task<string> LookupAsync(string input, CancellationToken cancellationToken)
    {
        if (!TryLookupAddress(input, out var address, out var prefix))
            throw new ArgumentException("Enter a valid IPv4 or IPv6 address, optionally with a CIDR prefix.");

        var bootstrapName = address.IsV6 ? "ipv6.json" : "ipv4.json";
        using var bootstrapResponse = await Http.GetAsync($"https://data.iana.org/rdap/{bootstrapName}", cancellationToken);
        bootstrapResponse.EnsureSuccessStatusCode();
        using var bootstrap = JsonDocument.Parse(await bootstrapResponse.Content.ReadAsStringAsync(cancellationToken));
        var registry = FindRegistry(bootstrap.RootElement, address);
        var path = prefix is null ? $"ip/{address}" : $"ip/{address}/{prefix.Value}";
        var resultUri = new Uri(registry, path);
        using var resultResponse = await Http.GetAsync(resultUri.ToString(), cancellationToken);
        if (resultResponse.StatusCode == HttpStatusCode.NotFound)
            throw new InvalidOperationException($"The registry has no record for {address}.");
        if (resultResponse.StatusCode == (HttpStatusCode)429)
            throw new InvalidOperationException("The registry is rate-limiting requests. Wait a minute and try again.");
        resultResponse.EnsureSuccessStatusCode();
        using var result = JsonDocument.Parse(await resultResponse.Content.ReadAsStringAsync(cancellationToken));

        var root = result.RootElement;
        var answeringUri = resultResponse.RequestMessage?.RequestUri ?? resultUri;
        var lines = new List<string> { $"Query: {address}{(prefix is null ? "" : $"/{prefix}")}", $"Registry: {root.String("port43") ?? resultResponse.RequestMessage?.RequestUri?.Host ?? registry.Host}" };
        var network = root.String("name") ?? root.String("handle");
        if (!string.IsNullOrWhiteSpace(network)) lines.Add($"Network: {network}");
        var networkHandle = root.String("handle");
        if (!string.IsNullOrWhiteSpace(networkHandle)) lines.Add($"Network handle: {networkHandle}");
        var currentOwner = FindRegistrant(root);
        if (currentOwner is not null)
        {
            lines.Add($"Owner: {currentOwner.Value.Name ?? currentOwner.Value.Handle}");
            lines.Add($"Owner handle: {currentOwner.Value.Handle}");
            var ownedCidrs = new HashSet<string>(StringComparer.Ordinal);
            AddCidrs(root, ownedCidrs);
            var answeringBase = RdapBaseUri(answeringUri) ?? registry;
            var ownerUri = currentOwner.Value.SelfUrl ??
                           new Uri(answeringBase, $"entity/{Uri.EscapeDataString(currentOwner.Value.Handle)}");
            try
            {
                using var ownerResponse = await Http.GetAsync(ownerUri.ToString(), cancellationToken);
                if (ownerResponse.IsSuccessStatusCode)
                {
                    using var ownerDocument = JsonDocument.Parse(await ownerResponse.Content.ReadAsStringAsync(cancellationToken));
                    if (currentOwner.Value.Name is null && VcardValue(ownerDocument.RootElement, "fn") is { } ownerName)
                        lines[lines.FindIndex(line => line.StartsWith("Owner: ", StringComparison.Ordinal))] = $"Owner: {ownerName}";
                    if (ownerDocument.RootElement.TryGetProperty("networks", out var networks) && networks.ValueKind == JsonValueKind.Array)
                        foreach (var item in networks.EnumerateArray()) AddCidrs(item, ownedCidrs);
                }
            }
            catch (Exception error) when (error is HttpRequestException or JsonException) { }

            if (IsRipeRegistry(answeringUri) && currentOwner.Value.Handle.StartsWith("ORG-", StringComparison.OrdinalIgnoreCase))
            {
                try { await AddRipeInverseSearchCidrsAsync(currentOwner.Value.Handle, ownedCidrs, cancellationToken); }
                catch (Exception error) when (error is HttpRequestException or JsonException) { }
            }

            if (ownedCidrs.Count > 0)
                lines.Add("\nNetworks registered to owner:\n" + string.Join(Environment.NewLine, SortCidrs(ownedCidrs)));
        }
        else
        {
            lines.Add("Owner: Not identified by the registry");
        }

        if (IsPublic(address))
        {
            try
            {
                var location = await LocateAsync(address.ToString(), cancellationToken);
                lines.Add("\nGeolocation:\n" + location);
            }
            catch (Exception error) when (error is HttpRequestException or InvalidOperationException or JsonException)
            {
                lines.Add($"\nGeolocation unavailable: {error.Message}");
            }
        }
        else lines.Add("\nGeolocation: unavailable for a non-public address.");
        return string.Join(Environment.NewLine, lines);
    }

    public static async Task<string> CheckReputationAsync(string input, string key, CancellationToken cancellationToken)
    {
        if (!TryLookupAddress(input, out var address, out _))
            throw new ArgumentException("Enter a valid IPv4 or IPv6 address or CIDR.");
        if (!IsPublic(address)) throw new InvalidOperationException("Reputation checks are available only for public IP addresses.");
        if (string.IsNullOrWhiteSpace(key) || key.Any(character => character < 33 || character > 126))
            throw new ArgumentException("Enter a valid AbuseIPDB API key.");

        var builder = new UriBuilder("https://api.abuseipdb.com/api/v2/check")
        {
            Query = $"ipAddress={Uri.EscapeDataString(address.ToString())}&maxAgeInDays=90"
        };
        using var request = new HttpRequestMessage(HttpMethod.Get, builder.Uri);
        request.Headers.Add("Key", key);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await NoRedirectHttp.SendAsync(request, cancellationToken);
        if (response.StatusCode == (HttpStatusCode)429)
            throw new InvalidOperationException("AbuseIPDB API quota exceeded. Try again later.");
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new InvalidOperationException("AbuseIPDB rejected the API key. Check your key and account permissions.");
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
        if (!document.RootElement.TryGetProperty("data", out var data))
            throw new InvalidOperationException("AbuseIPDB returned an invalid response.");
        var rows = new List<string>
        {
            $"IP address: {data.String("ipAddress") ?? address.ToString()}",
            $"Abuse confidence: {data.Int("abuseConfidenceScore")}%",
            $"Reports (last 90 days): {data.Int("totalReports")}",
            $"Distinct reporters: {data.Int("numDistinctUsers")}",
            $"Last reported: {data.String("lastReportedAt") ?? "Never"}"
        };
        AddIfPresent(rows, data, "countryCode", "Country");
        AddIfPresent(rows, data, "usageType", "Usage");
        AddIfPresent(rows, data, "isp", "ISP");
        AddIfPresent(rows, data, "domain", "Domain");
        if (data.TryGetProperty("isWhitelisted", out var allowlisted) && allowlisted.ValueKind is JsonValueKind.True or JsonValueKind.False)
            rows.Add($"Allowlisted: {allowlisted.GetBoolean()}");
        if (data.TryGetProperty("isTor", out var isTor) && isTor.ValueKind is JsonValueKind.True or JsonValueKind.False)
            rows.Add($"Tor exit node: {isTor.GetBoolean()}");
        return "Source: AbuseIPDB\n" + string.Join(Environment.NewLine, rows);
    }

    public static async Task<string> RunSpeedTestAsync(IProgress<string> progress, CancellationToken cancellationToken)
    {
        var samples = new List<double>();
        progress.Report("Warming up");
        await TransferAsync(1, false, cancellationToken);
        for (var index = 0; index < 5; index++)
        {
            progress.Report($"Measuring latency {index + 1}/5");
            samples.Add(await TransferAsync(1, false, cancellationToken) * 1000);
        }
        var downloadSeconds = 0d;
        for (var index = 0; index < 3; index++)
        {
            progress.Report($"Downloading {index + 1}/3");
            downloadSeconds += await TransferAsync(10_000_000, false, cancellationToken);
        }
        var uploadSeconds = 0d;
        for (var index = 0; index < 3; index++)
        {
            progress.Report($"Uploading {index + 1}/3");
            uploadSeconds += await TransferAsync(2_000_000, true, cancellationToken);
        }
        var latency = samples.Order().ElementAt(samples.Count / 2);
        progress.Report("Complete");
        return string.Format(CultureInfo.InvariantCulture,
            "Cloudflare Speed Test\nDownload: {0:F2} Mbps\nUpload: {1:F2} Mbps\nHTTP latency: {2:F1} ms\nCompleted: {3:G}",
            30_000_000 * 8 / downloadSeconds / 1_000_000,
            6_000_000 * 8 / uploadSeconds / 1_000_000, latency, DateTimeOffset.Now);
    }

    public static async Task RunNetworkCommandAsync(string tool, string target, int count, bool continuous,
        int maxHops, bool resolveNames, string portMode, string customPorts,
        Action<string> onLine, CancellationToken cancellationToken)
    {
        var parsedAddress = TryLookupAddress(target, out var address, out var prefix);
        if (!parsedAddress && !IsHostname(target))
            throw new ArgumentException("Enter a valid IP address, hostname, or CIDR.");
        var scanTarget = parsedAddress && prefix is not null ? $"{address}/{prefix.Value}" : address?.ToString() ?? target;

        var startInfo = new ProcessStartInfo { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        switch (tool)
        {
            case "Ping":
                startInfo.FileName = "ping.exe";
                if (address?.IsV6 == true) startInfo.ArgumentList.Add("-6");
                if (resolveNames) startInfo.ArgumentList.Add("-a");
                if (continuous) startInfo.ArgumentList.Add("-t");
                else { startInfo.ArgumentList.Add("-n"); startInfo.ArgumentList.Add(Math.Clamp(count, 4, 100).ToString(CultureInfo.InvariantCulture)); }
                startInfo.ArgumentList.Add("-w"); startInfo.ArgumentList.Add("2000");
                startInfo.ArgumentList.Add(address?.ToString() ?? target);
                break;
            case "Traceroute":
                startInfo.FileName = "tracert.exe";
                if (address?.IsV6 == true) startInfo.ArgumentList.Add("-6");
                if (!resolveNames) startInfo.ArgumentList.Add("-d");
                startInfo.ArgumentList.Add("-h"); startInfo.ArgumentList.Add(Math.Clamp(maxHops, 1, 64).ToString(CultureInfo.InvariantCulture));
                startInfo.ArgumentList.Add("-w"); startInfo.ArgumentList.Add("2000");
                startInfo.ArgumentList.Add(address?.ToString() ?? target);
                break;
            case "Port Scan":
                if (prefix is not null && prefix.Value < (address.IsV6 ? 120 : 20))
                    throw new ArgumentException($"Scan ranges must be /{(address.IsV6 ? 120 : 20)} or smaller.");
                startInfo.FileName = FindNmap() ?? throw new InvalidOperationException("nmap was not found. Install it from nmap.org and add it to PATH.");
                startInfo.ArgumentList.Add("-sT"); startInfo.ArgumentList.Add("-T4"); startInfo.ArgumentList.Add("--stats-every"); startInfo.ArgumentList.Add("5s");
                if (address?.IsV6 == true) startInfo.ArgumentList.Add("-6");
                if (portMode == "Top 100") startInfo.ArgumentList.Add("-F");
                else if (portMode == "All") startInfo.ArgumentList.Add("-p-");
                else if (portMode == "Custom")
                {
                    if (!ValidPorts(customPorts)) throw new ArgumentException("Use a port list such as 22,80,443 or 8000-8100.");
                    startInfo.ArgumentList.Add("-p"); startInfo.ArgumentList.Add(customPorts.Replace(" ", ""));
                }
                startInfo.ArgumentList.Add("-sV"); startInfo.ArgumentList.Add("--version-light"); startInfo.ArgumentList.Add("--open");
                if (prefix is null) startInfo.ArgumentList.Add("-Pn");
                if (resolveNames) startInfo.ArgumentList.Add("-R");
                else startInfo.ArgumentList.Add("-n");
                startInfo.ArgumentList.Add(scanTarget);
                break;
            default:
                throw new ArgumentException("Choose Ping, Traceroute, or Port Scan.");
        }

        startInfo.Environment["LC_ALL"] = "C";
        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, args) => { if (args.Data is not null) onLine(args.Data); };
        process.ErrorDataReceived += (_, args) => { if (args.Data is not null) onLine(args.Data); };
        if (!process.Start()) throw new InvalidOperationException("Could not start the Windows network tool.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
        });
        await process.WaitForExitAsync(cancellationToken);
    }

    public static string? LoadApiKey() => WindowsCredential.Read("IP Toolkit AbuseIPDB");
    public static void SaveApiKey(string key)
    {
        key = key.Trim();
        if (key.Length == 0 || key.Any(character => character < 33 || character > 126))
            throw new ArgumentException("The API key must contain printable ASCII characters without spaces.");
        WindowsCredential.Write("IP Toolkit AbuseIPDB", key);
    }
    public static void RemoveApiKey() => WindowsCredential.Delete("IP Toolkit AbuseIPDB");

    private static async Task<string> LocateAsync(string ip, CancellationToken cancellationToken)
    {
        using var infoResponse = await Http.GetAsync($"https://ipinfo.io/{Uri.EscapeDataString(ip)}/json", cancellationToken);
        if (infoResponse.IsSuccessStatusCode)
        {
            using var info = JsonDocument.Parse(await infoResponse.Content.ReadAsStringAsync(cancellationToken));
            var root = info.RootElement;
            if (!root.TryGetProperty("error", out _) && root.String("ip") is not null)
            {
                var rows = new List<string>();
                AddIfPresent(rows, root, "city", "City");
                AddIfPresent(rows, root, "region", "Region");
                AddIfPresent(rows, root, "country", "Country");
                AddIfPresent(rows, root, "postal", "Postal code");
                AddIfPresent(rows, root, "loc", "Coordinates");
                AddIfPresent(rows, root, "timezone", "Time zone");
                AddIfPresent(rows, root, "org", "Organization / ASN");
                AddIfPresent(rows, root, "hostname", "Hostname");
                rows.Add("Source: ipinfo.io");
                return string.Join(Environment.NewLine, rows);
            }
        }

        using var fallback = await Http.GetAsync($"https://ipwho.is/{Uri.EscapeDataString(ip)}", cancellationToken);
        fallback.EnsureSuccessStatusCode();
        using var whois = JsonDocument.Parse(await fallback.Content.ReadAsStringAsync(cancellationToken));
        var data = whois.RootElement;
        if (!data.TryGetProperty("success", out var success) || success.ValueKind != JsonValueKind.True)
            throw new InvalidOperationException(data.String("message") ?? "No geolocation data was returned.");
        var result = new List<string>();
        AddIfPresent(result, data, "city", "City");
        AddIfPresent(result, data, "region", "Region");
        AddIfPresent(result, data, "country", "Country");
        AddIfPresent(result, data, "postal", "Postal code");
        AddIfPresent(result, data, "latitude", "Latitude");
        AddIfPresent(result, data, "longitude", "Longitude");
        if (data.TryGetProperty("connection", out var connection))
        {
            AddIfPresent(result, connection, "org", "Organization");
            AddIfPresent(result, connection, "asn", "ASN");
        }
        if (data.TryGetProperty("timezone", out var timezone)) AddIfPresent(result, timezone, "id", "Time zone");
        result.Add("Source: ipwho.is");
        return string.Join(Environment.NewLine, result);
    }

    private static async Task<double> TransferAsync(int bytes, bool upload, CancellationToken cancellationToken)
    {
        var path = upload ? "__up" : "__down";
        var url = $"https://speed.cloudflare.com/{path}?requestId={Guid.NewGuid():N}" + (upload ? "" : $"&bytes={bytes}");
        using var request = new HttpRequestMessage(upload ? HttpMethod.Post : HttpMethod.Get, url);
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        if (upload) request.Content = new ByteArrayContent(Encoding.ASCII.GetBytes(new string('a', bytes)));
        var watch = Stopwatch.StartNew();
        using var response = await NoRedirectHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        if (upload)
        {
            if (!response.Headers.TryGetValues("cf-meta-upload-bytes", out var header) ||
                !int.TryParse(header.FirstOrDefault(), out var received) || received != bytes)
                throw new InvalidOperationException("Cloudflare did not confirm the expected upload size.");
        }
        else
        {
            var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (data.Length != bytes) throw new InvalidOperationException("Cloudflare returned an incomplete download.");
        }
        watch.Stop();
        return watch.Elapsed.TotalSeconds;
    }

    private static Uri FindRegistry(JsonElement bootstrap, NetAddress address)
    {
        if (!bootstrap.TryGetProperty("services", out var services))
            throw new InvalidOperationException("IANA RDAP bootstrap data was unavailable.");
        Uri? best = null;
        var longestPrefix = -1;
        foreach (var service in services.EnumerateArray())
        {
            if (service.GetArrayLength() < 2) continue;
            var prefixes = service[0];
            var urls = service[1];
            if (prefixes.ValueKind != JsonValueKind.Array || urls.ValueKind != JsonValueKind.Array) continue;
            var url = urls.EnumerateArray().Select(item => item.GetString()).FirstOrDefault(value => value?.StartsWith("https://", StringComparison.OrdinalIgnoreCase) == true);
            if (url is null || !Uri.TryCreate(url.EndsWith('/') ? url : url + "/", UriKind.Absolute, out var registry)) continue;
            foreach (var prefix in prefixes.EnumerateArray())
            {
                var value = prefix.GetString();
                if (value is null || !SubnetInfo.TryParse(value, out var cidr) || cidr.Address.IsV6 != address.IsV6) continue;
                if (cidr.PrefixLength > longestPrefix && address.Value >= cidr.NetworkAddress.Value && address.Value <= cidr.LastAddress.Value)
                {
                    longestPrefix = cidr.PrefixLength;
                    best = registry;
                }
            }
        }
        return best ?? throw new InvalidOperationException($"No RDAP registry is registered for {address}.");
    }

    private static (string Handle, string? Name, Uri? SelfUrl)? FindRegistrant(JsonElement root)
    {
        if (!root.TryGetProperty("entities", out var entities) || entities.ValueKind != JsonValueKind.Array) return null;
        (string Handle, string? Name, Uri? SelfUrl)? best = null;
        var bestScore = int.MinValue;
        foreach (var entity in entities.EnumerateArray())
        {
            if (!entity.TryGetProperty("roles", out var roles) || roles.ValueKind != JsonValueKind.Array ||
                !roles.EnumerateArray().Any(role => role.GetString() == "registrant")) continue;
            var handle = entity.String("handle");
            if (handle is null) continue;
            var name = VcardValue(entity, "fn");
            Uri? self = null;
            if (entity.TryGetProperty("links", out var links) && links.ValueKind == JsonValueKind.Array)
                foreach (var link in links.EnumerateArray())
                    if (link.String("rel") == "self" && Uri.TryCreate(link.String("href"), UriKind.Absolute, out var parsed) && parsed.Scheme == "https") self = parsed;

            var score = VcardValue(entity, "kind")?.Equals("org", StringComparison.OrdinalIgnoreCase) == true ? 2 : 0;
            if (handle.EndsWith("-MNT", StringComparison.OrdinalIgnoreCase)) score -= 2;
            if (score > bestScore)
            {
                best = (handle, name, self);
                bestScore = score;
            }
        }
        return best;
    }

    private static string? VcardValue(JsonElement entity, string propertyName)
    {
        if (!entity.TryGetProperty("vcardArray", out var card) || card.ValueKind != JsonValueKind.Array || card.GetArrayLength() < 2 ||
            card[1].ValueKind != JsonValueKind.Array) return null;
        foreach (var property in card[1].EnumerateArray())
            if (property.ValueKind == JsonValueKind.Array && property.GetArrayLength() >= 4 &&
                property[0].GetString() == propertyName && property[3].ValueKind == JsonValueKind.String)
                return property[3].GetString();
        return null;
    }

    private static Uri? RdapBaseUri(Uri responseUri)
    {
        var path = responseUri.AbsolutePath;
        var ipPath = path.LastIndexOf("/ip/", StringComparison.OrdinalIgnoreCase);
        if (ipPath < 0) return null;
        return new UriBuilder(responseUri) { Path = path[..(ipPath + 1)], Query = "", Fragment = "" }.Uri;
    }

    private static bool IsRipeRegistry(Uri uri) =>
        uri.Host.Equals("ripe.net", StringComparison.OrdinalIgnoreCase) ||
        uri.Host.EndsWith(".ripe.net", StringComparison.OrdinalIgnoreCase);

    private static async Task AddRipeInverseSearchCidrsAsync(string orgHandle, ISet<string> cidrs, CancellationToken cancellationToken)
    {
        var query = $"query-string={Uri.EscapeDataString(orgHandle)}&inverse-attribute=org&type-filter=inetnum&type-filter=inet6num&flags=r";
        var searchUri = new Uri($"https://rest.db.ripe.net/search.json?{query}");
        using var request = new HttpRequestMessage(HttpMethod.Get, searchUri);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await Http.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode) return;
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
        AddRipeSearchCidrs(document.RootElement, cidrs);
    }

    private static void AddRipeSearchCidrs(JsonElement root, ISet<string> cidrs)
    {
        if (!root.TryGetProperty("objects", out var objects) ||
            !objects.TryGetProperty("object", out var records) || records.ValueKind != JsonValueKind.Array) return;
        foreach (var record in records.EnumerateArray())
        {
            if (!record.TryGetProperty("attributes", out var attributes) ||
                !attributes.TryGetProperty("attribute", out var values) || values.ValueKind != JsonValueKind.Array) continue;
            foreach (var attribute in values.EnumerateArray())
            {
                var name = attribute.String("name");
                var value = attribute.String("value");
                if (name == "inetnum" && value is not null)
                {
                    var range = value.Split('-', 2);
                    if (range.Length == 2 && NetAddress.TryParse(range[0], out var first) && NetAddress.TryParse(range[1], out var last))
                        AddRangeCidrs(first, last, cidrs);
                }
                else if (name == "inet6num" && value is not null && SubnetInfo.TryParse(value, out var subnet))
                {
                    cidrs.Add($"{subnet.NetworkAddress}/{subnet.PrefixLength}");
                }
            }
        }
    }

    private static void AddCidrs(JsonElement network, ISet<string> cidrs)
    {
        if (network.TryGetProperty("cidr0_cidrs", out var entries) && entries.ValueKind == JsonValueKind.Array)
            foreach (var entry in entries.EnumerateArray())
            {
                var ip = entry.String("v4prefix") ?? entry.String("v6prefix");
                if (ip is not null && entry.TryGetProperty("length", out var length) &&
                    int.TryParse(length.ToString(), out var prefix) && NetAddress.TryParse(ip, out var parsed))
                    cidrs.Add($"{parsed}/{prefix}");
            }
        if (network.String("startAddress") is { } start && network.String("endAddress") is { } end &&
            NetAddress.TryParse(start, out var first) && NetAddress.TryParse(end, out var last))
            AddRangeCidrs(first, last, cidrs);
    }

    private static void AddRangeCidrs(NetAddress first, NetAddress last, ISet<string> cidrs)
    {
        if (first.IsV6 != last.IsV6 || first.Value > last.Value) return;
        var current = first.Value;
        while (current <= last.Value)
        {
            var alignedBits = first.BitWidth;
            while (alignedBits > 0 && (current & ((BigInteger.One << alignedBits) - 1)) != 0) alignedBits--;
            var prefix = first.BitWidth - alignedBits;
            BigInteger blockSize;
            BigInteger blockLast;
            do
            {
                blockSize = BigInteger.One << (first.BitWidth - prefix);
                blockLast = current + blockSize - 1;
                if (blockLast <= last.Value) break;
                prefix++;
            } while (prefix <= first.BitWidth);
            cidrs.Add($"{NetAddress.FromValue(first.IsV6, current)}/{prefix}");
            current += blockSize;
        }
    }

    private static IEnumerable<string> SortCidrs(IEnumerable<string> cidrs) => cidrs
        .OrderBy(text => TryCidrAddress(text, out var address) && address.IsV6 ? 1 : 0)
        .ThenBy(text => TryCidrAddress(text, out var address) ? address.Value : BigInteger.Zero)
        .ThenBy(text => int.TryParse(text[(text.LastIndexOf('/') + 1)..], out var prefix) ? prefix : 0);

    private static bool TryCidrAddress(string text, out NetAddress address)
    {
        address = null!;
        var slash = text.LastIndexOf('/');
        return slash > 0 && NetAddress.TryParse(text[..slash], out address);
    }

    private static void AddIfPresent(List<string> rows, JsonElement source, string property, string label)
    {
        var value = source.String(property);
        if (!string.IsNullOrWhiteSpace(value)) rows.Add($"{label}: {value}");
    }

    private static bool TryLookupAddress(string input, out NetAddress address, out int? prefix)
    {
        address = null!;
        prefix = null;
        var parts = input.Trim().Split('/');
        if (parts.Length is < 1 or > 2 || !NetAddress.TryParse(parts[0], out address)) return false;
        if (parts.Length == 1) return true;
        if (!int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var length) || length < 0 || length > address.BitWidth) return false;
        prefix = length;
        if (!SubnetInfo.TryParse($"{address}/{length}", out var subnet)) return false;
        address = subnet.NetworkAddress;
        return true;
    }

    private static bool IsPublic(NetAddress address)
    {
        var ranges = address.IsV6
            ? new[] { "2000::/3" }
            : new[] { "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4" };
        var isInBase = !address.IsV6 || IsInRange(address, "2000::/3");
        var isSpecialV6 = address.IsV6 && (IsInRange(address, "2001:db8::/32") || IsInRange(address, "2001::/23"));
        return isInBase && !isSpecialV6 && !ranges.Any(text => IsInRange(address, text));
    }

    private static bool IsInRange(NetAddress address, string cidr) =>
        SubnetInfo.TryParse(cidr, out var range) && address.IsV6 == range.Address.IsV6 &&
        address.Value >= range.NetworkAddress.Value && address.Value <= range.LastAddress.Value;

    private static bool IsHostname(string target)
    {
        var labels = target.TrimEnd('.').Split('.');
        return target.Length <= 253 && labels.Any(label => label.Any(character => !char.IsAsciiDigit(character))) &&
               labels.All(label => label.Length is > 0 and <= 63 && label[0] != '-' && label[^1] != '-' &&
                                   label.All(character => char.IsAsciiLetterOrDigit(character) || character == '-'));
    }

    private static string? FindNmap()
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var candidate = Path.Combine(directory, "nmap.exe");
            if (File.Exists(candidate)) return candidate;
        }
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var standard = Path.Combine(programFiles, "Nmap", "nmap.exe");
        return File.Exists(standard) ? standard : null;
    }

    private static bool ValidPorts(string text)
    {
        var items = text.Replace(" ", "").Split(',');
        if (items.Length == 0 || items.Length > 100) return false;
        foreach (var item in items)
        {
            var parts = item.Split('-');
            if (parts.Length is < 1 or > 2 || !int.TryParse(parts[0], out var first) || first is < 1 or > 65535) return false;
            var last = first;
            if (parts.Length == 2 && (!int.TryParse(parts[1], out last) || last is < 1 or > 65535 || first > last)) return false;
        }
        return true;
    }

    private static class WindowsCredential
    {
        private const uint Generic = 1;
        private const uint LocalMachine = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Credential
        {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string? Comment;
            public long LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string? TargetAlias;
            public string? UserName;
        }

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredWrite(ref Credential credential, uint flags);
        [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredDelete(string target, uint type, uint flags);
        [DllImport("Advapi32.dll", SetLastError = false)]
        private static extern void CredFree(IntPtr buffer);

        public static string? Read(string target)
        {
            if (!CredRead(target, Generic, 0, out var pointer)) return null;
            try
            {
                var credential = Marshal.PtrToStructure<Credential>(pointer);
                return Marshal.PtrToStringUni(credential.CredentialBlob, checked((int)credential.CredentialBlobSize / 2));
            }
            finally { CredFree(pointer); }
        }

        public static void Write(string target, string value)
        {
            var bytes = Encoding.Unicode.GetBytes(value);
            var blob = Marshal.AllocHGlobal(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, blob, bytes.Length);
                var credential = new Credential
                {
                    Type = Generic,
                    TargetName = target,
                    CredentialBlob = blob,
                    CredentialBlobSize = (uint)bytes.Length,
                    Persist = LocalMachine,
                    UserName = Environment.UserName
                };
                if (!CredWrite(ref credential, 0)) throw new InvalidOperationException("Windows could not save the API key in Credential Manager.");
            }
            finally { Marshal.FreeHGlobal(blob); }
        }

        public static void Delete(string target)
        {
            if (!CredDelete(target, Generic, 0) && Marshal.GetLastWin32Error() != 1168)
                throw new InvalidOperationException("Windows could not remove the saved API key.");
        }
    }
}

internal static class JsonElementExtensions
{
    public static string? String(this JsonElement element, string property) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    public static int Int(this JsonElement element, string property) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(property, out var value) && value.TryGetInt32(out var number)
            ? number : 0;
}