using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace Programa;

internal enum TypeSafeCredentialSource
{
    Saved,
    Environment,
}

internal enum TypeSafeCredentialLookupKind
{
    Available,
    Missing,
    Unavailable,
}

internal readonly record struct TypeSafeCredential(string Value, TypeSafeCredentialSource Source);

internal readonly record struct TypeSafeCredentialLookup(
    TypeSafeCredentialLookupKind Kind,
    TypeSafeCredential? Credential = null
);

internal enum TypeSafeCredentialOperation
{
    Success,
    Blank,
    InvalidCharacters,
    Unavailable,
}

internal enum TypeSafeCredentialStorageReadKind
{
    Value,
    Missing,
    Unavailable,
}

internal readonly record struct TypeSafeCredentialStorageRead(
    TypeSafeCredentialStorageReadKind Kind,
    string? Value = null
);

internal sealed class TypeSafeCredentialStore
{
    internal const string EnvironmentVariableName = "TYPESAFE_API_KEY";

    private const int CredentialTypeGeneric = 1;
    private const int CredentialPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;
    private const string CredentialUserName = "jev-api-key";
    private const string DiscoveryValueName = "DiscoverEnvironmentCredential";

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private readonly Func<TypeSafeCredentialStorageRead> _readSavedCredential;
    private readonly Func<string, bool> _writeSavedCredential;
    private readonly Func<bool> _removeSavedCredential;
    private readonly Func<string?> _readEnvironmentCredential;
    private readonly Func<bool> _readEnvironmentDiscovery;
    private readonly Func<bool, bool> _writeEnvironmentDiscovery;

    internal TypeSafeCredentialStore()
        : this(
            ReadNativeCredential,
            WriteNativeCredential,
            RemoveNativeCredential,
            () => Environment.GetEnvironmentVariable(EnvironmentVariableName),
            ReadEnvironmentDiscovery,
            WriteEnvironmentDiscovery
        )
    {
    }

    internal TypeSafeCredentialStore(
        Func<TypeSafeCredentialStorageRead> readSavedCredential,
        Func<string, bool> writeSavedCredential,
        Func<bool> removeSavedCredential,
        Func<string?> readEnvironmentCredential,
        Func<bool> readEnvironmentDiscovery,
        Func<bool, bool> writeEnvironmentDiscovery
    )
    {
        _readSavedCredential = readSavedCredential;
        _writeSavedCredential = writeSavedCredential;
        _removeSavedCredential = removeSavedCredential;
        _readEnvironmentCredential = readEnvironmentCredential;
        _readEnvironmentDiscovery = readEnvironmentDiscovery;
        _writeEnvironmentDiscovery = writeEnvironmentDiscovery;
    }

    internal bool EnvironmentDiscoveryEnabled => _readEnvironmentDiscovery();

    internal bool SetEnvironmentDiscoveryEnabled(bool enabled) =>
        _writeEnvironmentDiscovery(enabled);

    internal TypeSafeCredentialLookup Credential()
    {
        var saved = _readSavedCredential();
        if (saved.Kind == TypeSafeCredentialStorageReadKind.Unavailable)
            return new(TypeSafeCredentialLookupKind.Unavailable);
        if (saved.Kind == TypeSafeCredentialStorageReadKind.Value)
        {
            var normalized = Normalize(saved.Value);
            return normalized is null
                ? new(TypeSafeCredentialLookupKind.Unavailable)
                : new(
                    TypeSafeCredentialLookupKind.Available,
                    new TypeSafeCredential(normalized, TypeSafeCredentialSource.Saved)
                );
        }

        if (!_readEnvironmentDiscovery())
            return new(TypeSafeCredentialLookupKind.Missing);

        var environmentCredential = Normalize(_readEnvironmentCredential());
        return environmentCredential is null
            ? new(TypeSafeCredentialLookupKind.Missing)
            : new(
                TypeSafeCredentialLookupKind.Available,
                new TypeSafeCredential(environmentCredential, TypeSafeCredentialSource.Environment)
            );
    }

    internal TypeSafeCredentialOperation Save(string candidate)
    {
        var trimmed = candidate.Trim();
        if (trimmed.Length == 0)
            return TypeSafeCredentialOperation.Blank;
        if (trimmed.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)))
            return TypeSafeCredentialOperation.InvalidCharacters;
        return _writeSavedCredential(trimmed)
            ? TypeSafeCredentialOperation.Success
            : TypeSafeCredentialOperation.Unavailable;
    }

    internal TypeSafeCredentialOperation Remove() =>
        _removeSavedCredential()
            ? TypeSafeCredentialOperation.Success
            : TypeSafeCredentialOperation.Unavailable;

    private static string? Normalize(string? candidate)
    {
        if (candidate is null)
            return null;
        var trimmed = candidate.Trim();
        return trimmed.Length > 0
            && !trimmed.Any(character => char.IsWhiteSpace(character) || char.IsControl(character))
                ? trimmed
                : null;
    }

    private static string CredentialTarget
    {
        get
        {
            var assemblyName = Assembly.GetEntryAssembly()?.GetName().Name ?? "programa";
#if DEBUG
            return $"DarkroomEngineering_{assemblyName}_Debug_TypeSafeJev";
#else
            return $"DarkroomEngineering_{assemblyName}_TypeSafeJev";
#endif
        }
    }

    private static string RegistryPath
    {
        get
        {
#if DEBUG
            return @"Software\Darkroom Engineering\Programa\Debug";
#else
            return @"Software\Darkroom Engineering\Programa";
#endif
        }
    }

    private static bool ReadEnvironmentDiscovery()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return ResolveEnvironmentDiscoveryPreference(
                readSucceeded: true,
                value: key?.GetValue(DiscoveryValueName)
            );
        }
        catch
        {
            return ResolveEnvironmentDiscoveryPreference(readSucceeded: false, value: null);
        }
    }

    internal static bool ResolveEnvironmentDiscoveryPreference(bool readSucceeded, object? value)
    {
        if (!readSucceeded)
            return false;
        return value switch
        {
            null => true,
            int intValue => intValue == 1,
            _ => false,
        };
    }

    private static bool WriteEnvironmentDiscovery(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
            key.SetValue(DiscoveryValueName, enabled ? 1 : 0, RegistryValueKind.DWord);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static TypeSafeCredentialStorageRead ReadNativeCredential()
    {
        if (!CredReadW(CredentialTarget, CredentialTypeGeneric, 0, out var pointer))
        {
            return Marshal.GetLastWin32Error() == ErrorNotFound
                ? new(TypeSafeCredentialStorageReadKind.Missing)
                : new(TypeSafeCredentialStorageReadKind.Unavailable);
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            if (credential.CredentialBlobSize == 0 || credential.CredentialBlob == IntPtr.Zero)
                return new(TypeSafeCredentialStorageReadKind.Unavailable);

            if (credential.CredentialBlobSize > int.MaxValue)
                return new(TypeSafeCredentialStorageReadKind.Unavailable);
            var bytes = new byte[(int)credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            try
            {
                return new(TypeSafeCredentialStorageReadKind.Value, StrictUtf8.GetString(bytes));
            }
            catch (DecoderFallbackException)
            {
                return new(TypeSafeCredentialStorageReadKind.Unavailable);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        finally
        {
            CredFree(pointer);
        }
    }

    private static unsafe bool WriteNativeCredential(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var target = CredentialTarget;
        var userNameValue = CredentialUserName;
        try
        {
            fixed (byte* blob = bytes)
            fixed (char* targetName = target)
            fixed (char* userName = userNameValue)
            {
                var credential = new NativeCredential
                {
                    Type = CredentialTypeGeneric,
                    TargetName = (IntPtr)targetName,
                    CredentialBlobSize = (uint)bytes.Length,
                    CredentialBlob = (IntPtr)blob,
                    Persist = CredentialPersistLocalMachine,
                    UserName = (IntPtr)userName,
                };
                return CredWriteW(ref credential, 0);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static bool RemoveNativeCredential()
    {
        if (CredDeleteW(CredentialTarget, CredentialTypeGeneric, 0))
            return true;
        return Marshal.GetLastWin32Error() == ErrorNotFound;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        internal uint Flags;
        internal uint Type;
        internal IntPtr TargetName;
        internal IntPtr Comment;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        internal uint CredentialBlobSize;
        internal IntPtr CredentialBlob;
        internal uint Persist;
        internal uint AttributeCount;
        internal IntPtr Attributes;
        internal IntPtr TargetAlias;
        internal IntPtr UserName;
    }

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredReadW(
        string target,
        int type,
        int reservedFlag,
        out IntPtr credential
    );

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWriteW(ref NativeCredential credential, uint flags);

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDeleteW(string target, int type, int flags);

    [DllImport("Advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
