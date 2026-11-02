using System.Globalization;
using System.Numerics;
using System.Net.Sockets;

namespace IPToolkit.Windows;

internal sealed class NetAddress
{
    private NetAddress(bool isV6, BigInteger value)
    {
        IsV6 = isV6;
        Value = value;
    }

    public bool IsV6 { get; }
    public int BitWidth => IsV6 ? 128 : 32;
    public BigInteger Value { get; }

    public static bool TryParse(string text, out NetAddress address)
    {
        address = null!;
        text = text.Trim();
        if (text.Length == 0 || text.Contains('%')) return false;

        if (text.Contains(':'))
        {
            if (!System.Net.IPAddress.TryParse(text, out var parsed) ||
                parsed.AddressFamily != AddressFamily.InterNetworkV6) return false;
            address = new NetAddress(true, new BigInteger(parsed.GetAddressBytes(), isUnsigned: true, isBigEndian: true));
            return true;
        }

        var octets = text.Split('.');
        if (octets.Length != 4) return false;
        var bytes = new byte[4];
        for (var index = 0; index < octets.Length; index++)
        {
            if (octets[index].Length is < 1 or > 3 ||
                !byte.TryParse(octets[index], NumberStyles.None, CultureInfo.InvariantCulture, out bytes[index]))
                return false;
        }

        address = new NetAddress(false, new BigInteger(bytes, isUnsigned: true, isBigEndian: true));
        return true;
    }

    public static NetAddress FromValue(bool isV6, BigInteger value) => new(isV6, value);

    public override string ToString()
    {
        var bytes = Value.ToByteArray(isUnsigned: true, isBigEndian: true);
        var width = BitWidth / 8;
        var padded = new byte[width];
        Array.Copy(bytes, 0, padded, width - bytes.Length, bytes.Length);
        if (IsV6) return new System.Net.IPAddress(padded).ToString();
        return string.Join('.', padded.Select(value => value.ToString(CultureInfo.InvariantCulture)));
    }
}

internal sealed class SubnetInfo
{
    private static readonly (string Prefix, string Label)[] SpecialRanges =
    [
        ("0.0.0.0/8", "This network"), ("10.0.0.0/8", "Private"),
        ("100.64.0.0/10", "Shared address space / CGNAT"), ("127.0.0.0/8", "Loopback"),
        ("169.254.0.0/16", "Link-local"), ("172.16.0.0/12", "Private"),
        ("192.0.0.0/24", "IETF protocol assignments"), ("192.0.2.0/24", "Documentation"),
        ("192.88.99.0/24", "Deprecated 6to4 relay anycast"), ("192.168.0.0/16", "Private"),
        ("198.18.0.0/15", "Benchmarking"), ("198.51.100.0/24", "Documentation"),
        ("203.0.113.0/24", "Documentation"), ("224.0.0.0/4", "Multicast"),
        ("240.0.0.0/4", "Reserved"), ("255.255.255.255/32", "Limited broadcast"),
        ("::/128", "Unspecified"), ("::1/128", "Loopback"),
        ("::ffff:0:0/96", "IPv4-mapped"), ("64:ff9b::/96", "NAT64 well-known prefix"),
        ("100::/64", "Discard-only"), ("2000::/3", "Global unicast (RFC 4291)"),
        ("2001::/32", "Teredo"), ("2001:db8::/32", "Documentation"),
        ("2002::/16", "6to4"), ("3fff::/20", "Documentation"),
        ("fc00::/7", "Unique local"), ("fe80::/10", "Link-local"), ("ff00::/8", "Multicast")
    ];

    private SubnetInfo(NetAddress address, int prefixLength)
    {
        Address = address;
        PrefixLength = prefixLength;
        var hostBits = address.BitWidth - prefixLength;
        var hostMask = (BigInteger.One << hostBits) - BigInteger.One;
        var networkValue = address.Value & ~hostMask;
        NetworkAddress = NetAddress.FromValue(address.IsV6, networkValue);
        LastAddress = NetAddress.FromValue(address.IsV6, networkValue | hostMask);
    }

    public NetAddress Address { get; }
    public NetAddress NetworkAddress { get; }
    public NetAddress LastAddress { get; }
    public int PrefixLength { get; }
    public IReadOnlyList<SubnetRow> Rows => BuildRows();

    public static bool TryParse(string text, out SubnetInfo subnet)
    {
        subnet = null!;
        text = text.Trim();
        if (text.Length == 0) return false;

        string[] parts;
        if (text.Contains('/'))
        {
            parts = text.Split('/');
            if (parts.Length != 2) return false;
            parts = parts.Select(part => part.Trim()).ToArray();
        }
        else
        {
            parts = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length is < 1 or > 2) return false;
        }

        if (!NetAddress.TryParse(parts[0], out var address)) return false;
        var prefix = address.BitWidth;
        if (parts.Length == 2)
        {
            var suffix = parts[1];
            if (suffix.Length == 0) return false;
            if (int.TryParse(suffix, NumberStyles.None, CultureInfo.InvariantCulture, out var parsedPrefix))
            {
                if (parsedPrefix < 0 || parsedPrefix > address.BitWidth) return false;
                prefix = parsedPrefix;
            }
            else
            {
                if (address.IsV6 || !NetAddress.TryParse(suffix, out var mask) || mask.IsV6 ||
                    !TryPrefixFromMask(mask.Value, out prefix)) return false;
            }
        }

        subnet = new SubnetInfo(address, prefix);
        return true;
    }

    public IReadOnlyList<SubnetRow> Split(int newPrefix, int limit = 1024)
    {
        if (newPrefix <= PrefixLength || newPrefix > Address.BitWidth || limit < 1) return [];
        var blockSize = BigInteger.One << (Address.BitWidth - newPrefix);
        var rows = new List<SubnetRow>();
        var current = NetworkAddress.Value;
        for (var index = 0; index < limit && current <= LastAddress.Value; index++, current += blockSize)
            rows.Add(new SubnetRow($"Subnet {index + 1}", $"{NetAddress.FromValue(Address.IsV6, current)}/{newPrefix}"));
        return rows;
    }

    private IReadOnlyList<SubnetRow> BuildRows()
    {
        var rows = new List<SubnetRow> { new("Address", Address.ToString()) };
        rows.Add(new("Network", $"{NetworkAddress}/{PrefixLength}"));

        if (!Address.IsV6)
        {
            var hostBits = 32 - PrefixLength;
            var mask = hostBits == 32 ? BigInteger.Zero : ((BigInteger.One << 32) - 1) ^ ((BigInteger.One << hostBits) - 1);
            rows.Add(new("Netmask", NetAddress.FromValue(false, mask).ToString()));
            rows.Add(new("Wildcard mask", NetAddress.FromValue(false, (BigInteger.One << hostBits) - 1).ToString()));
            rows.Add(new("Broadcast", PrefixLength <= 30 ? LastAddress.ToString() : "None (point-to-point or single host)"));
            rows.Add(new("First usable host", PrefixLength <= 30 ? NetAddress.FromValue(false, NetworkAddress.Value + 1).ToString() : NetworkAddress.ToString()));
            rows.Add(new("Last usable host", PrefixLength <= 30 ? NetAddress.FromValue(false, LastAddress.Value - 1).ToString() : LastAddress.ToString()));
            rows.Add(new("Total addresses", (BigInteger.One << hostBits).ToString("N0", CultureInfo.InvariantCulture)));
            rows.Add(new("Usable hosts", PrefixLength switch { 32 => "1", 31 => "2", _ => ((BigInteger.One << hostBits) - 2).ToString("N0", CultureInfo.InvariantCulture) }));
            rows.Add(new("Address type", Classify()));
            rows.Add(new("Legacy class", LegacyClass()));
            rows.Add(new("Binary address", Binary(Address.Value)));
            rows.Add(new("Binary netmask", Binary(mask)));
        }
        else
        {
            rows.Add(new("Expanded", Expanded(Address.Value)));
            rows.Add(new("First address", NetworkAddress.ToString()));
            rows.Add(new("Last address", LastAddress.ToString()));
            var hostBits = Address.BitWidth - PrefixLength;
            var total = (BigInteger.One << hostBits).ToString("N0", CultureInfo.InvariantCulture);
            rows.Add(new("Total addresses", hostBits >= 20 ? $"{total} (2^{hostBits})" : total));
            if (PrefixLength < 64)
                rows.Add(new("/64 subnets", (BigInteger.One << (64 - PrefixLength)).ToString("N0", CultureInfo.InvariantCulture)));
            rows.Add(new("Address type", Classify()));
        }

        return rows;
    }

    private string Classify()
    {
        var matches = SpecialRanges
            .Select(entry => (entry.Label, Subnet: TryParse(entry.Prefix, out var subnet) ? subnet : null))
            .Where(entry => entry.Subnet is not null && entry.Subnet.Address.IsV6 == Address.IsV6)
            .Select(entry => (entry.Label, Subnet: entry.Subnet!))
            .ToArray();
        var enclosing = matches
            .Where(entry => entry.Subnet.PrefixLength <= PrefixLength &&
                            NetworkAddress.Value >= entry.Subnet.NetworkAddress.Value &&
                            NetworkAddress.Value <= entry.Subnet.LastAddress.Value)
            .OrderByDescending(entry => entry.Subnet.PrefixLength)
            .FirstOrDefault();
        var containsOtherSpecial = matches.Any(entry => entry.Subnet.PrefixLength > PrefixLength &&
            entry.Subnet.NetworkAddress.Value >= NetworkAddress.Value && entry.Subnet.NetworkAddress.Value <= LastAddress.Value &&
            (enclosing.Subnet is null || entry.Label != enclosing.Label));
        if (containsOtherSpecial) return "Mixed (contains special-purpose ranges)";
        if (enclosing.Subnet is not null) return enclosing.Label;
        return Address.IsV6 ? "Reserved by IETF" : "Public (globally routable)";
    }

    private string LegacyClass()
    {
        var firstOctet = (int)((Address.Value >> 24) & 255);
        return firstOctet switch
        {
            < 128 => "A",
            < 192 => "B",
            < 224 => "C",
            < 240 => "D (multicast)",
            _ => "E (reserved)"
        };
    }

    private static bool TryPrefixFromMask(BigInteger mask, out int prefix)
    {
        prefix = 0;
        var sawZero = false;
        for (var bit = 31; bit >= 0; bit--)
        {
            var set = (mask & (BigInteger.One << bit)) != 0;
            if (set && sawZero) return false;
            if (set) prefix++;
            else sawZero = true;
        }
        return true;
    }

    private static string Binary(BigInteger value)
    {
        var bits = Convert.ToString((long)(uint)(value & uint.MaxValue), 2).PadLeft(32, '0');
        return string.Join('.', Enumerable.Range(0, 4).Select(index => bits.Substring(index * 8, 8)));
    }

    private static string Expanded(BigInteger value)
    {
        var bytes = value.ToByteArray(isUnsigned: true, isBigEndian: true);
        var padded = new byte[16];
        Array.Copy(bytes, 0, padded, 16 - bytes.Length, bytes.Length);
        return string.Join(':', Enumerable.Range(0, 8).Select(index =>
            ((padded[index * 2] << 8) | padded[index * 2 + 1]).ToString("x4", CultureInfo.InvariantCulture)));
    }
}

internal sealed record SubnetRow(string Label, string Value);