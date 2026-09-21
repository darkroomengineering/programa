using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class TypeSafeCredentialStoreTests
{
    [TestMethod]
    public void SavedCredentialWinsWithoutConsultingDiscoveryOrEnvironment()
    {
        var backend = new FakeCredentialBackend
        {
            SavedKind = TypeSafeCredentialStorageReadKind.Value,
            SavedValue = "  saved-token  ",
            EnvironmentValue = "environment-token",
        };

        var lookup = backend.Store.Credential();

        Assert.AreEqual(TypeSafeCredentialLookupKind.Available, lookup.Kind);
        Assert.AreEqual(new TypeSafeCredential("saved-token", TypeSafeCredentialSource.Saved), lookup.Credential);
        Assert.AreEqual(0, backend.DiscoveryReadCount);
        Assert.AreEqual(0, backend.EnvironmentReadCount);
    }

    [TestMethod]
    public void EnvironmentDiscoveryIsOptionalAndRejectsBlankValues()
    {
        var backend = new FakeCredentialBackend { EnvironmentValue = "  environment-token  " };

        var discovered = backend.Store.Credential();
        Assert.AreEqual(TypeSafeCredentialLookupKind.Available, discovered.Kind);
        Assert.AreEqual(
            new TypeSafeCredential("environment-token", TypeSafeCredentialSource.Environment),
            discovered.Credential
        );

        backend.EnvironmentValue = " \r\n\t ";
        Assert.AreEqual(TypeSafeCredentialLookupKind.Missing, backend.Store.Credential().Kind);
    }

    [TestMethod]
    public void DisabledDiscoveryDoesNotReadEnvironment()
    {
        var backend = new FakeCredentialBackend
        {
            DiscoveryEnabled = false,
            EnvironmentValue = "environment-token",
        };

        Assert.AreEqual(TypeSafeCredentialLookupKind.Missing, backend.Store.Credential().Kind);
        Assert.AreEqual(0, backend.EnvironmentReadCount, "opt-out must prevent even probing the process environment");
    }

    [TestMethod]
    public void DiscoveryPreferenceDefaultsOnOnlyForAReadableMissingValueOrDwordOne()
    {
        Assert.IsTrue(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, null));
        Assert.IsTrue(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, 1));
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, 0));
    }

    [TestMethod]
    public void DiscoveryPreferenceFailsClosedForReadErrorsAndMalformedValues()
    {
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(false, null));
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(false, 1));
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, -1));
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, 2));
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, "1"));
        Assert.IsFalse(TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(true, 1L));
    }

    [TestMethod]
    public void FailedPreferenceReadPreventsEnvironmentCredentialAccess()
    {
        var environmentReadCount = 0;
        var store = new TypeSafeCredentialStore(
            () => new TypeSafeCredentialStorageRead(TypeSafeCredentialStorageReadKind.Missing),
            _ => true,
            () => true,
            () =>
            {
                environmentReadCount++;
                return "environment-token";
            },
            () => TypeSafeCredentialStore.ResolveEnvironmentDiscoveryPreference(false, null),
            _ => true
        );

        Assert.AreEqual(TypeSafeCredentialLookupKind.Missing, store.Credential().Kind);
        Assert.AreEqual(0, environmentReadCount, "a registry read failure must not expose the process environment");
    }

    [TestMethod]
    public void StorageFailureIsUnavailableWithoutEnvironmentFallback()
    {
        var backend = new FakeCredentialBackend
        {
            SavedKind = TypeSafeCredentialStorageReadKind.Unavailable,
            EnvironmentValue = "environment-token",
        };

        Assert.AreEqual(TypeSafeCredentialLookupKind.Unavailable, backend.Store.Credential().Kind);
        Assert.AreEqual(0, backend.DiscoveryReadCount);
        Assert.AreEqual(0, backend.EnvironmentReadCount, "a Credential Manager failure must not silently change credential source");
    }

    [TestMethod]
    public void SuccessfulSaveRemoveAndDiscoveryPreferenceDriveStateTransitions()
    {
        var backend = new FakeCredentialBackend();

        Assert.AreEqual(TypeSafeCredentialOperation.Success, backend.Store.Save("  saved-token  "));
        CollectionAssert.AreEqual(new[] { "saved-token" }, backend.WriteAttempts);
        Assert.AreEqual(
            new TypeSafeCredential("saved-token", TypeSafeCredentialSource.Saved),
            backend.Store.Credential().Credential
        );

        Assert.AreEqual(TypeSafeCredentialOperation.Success, backend.Store.Remove());
        Assert.AreEqual(1, backend.RemoveAttemptCount);
        Assert.AreEqual(TypeSafeCredentialLookupKind.Missing, backend.Store.Credential().Kind);

        Assert.IsTrue(backend.Store.SetEnvironmentDiscoveryEnabled(false));
        Assert.IsFalse(backend.DiscoveryEnabled);
        backend.DiscoveryWriteSucceeds = false;
        Assert.IsFalse(backend.Store.SetEnvironmentDiscoveryEnabled(true));
        Assert.IsFalse(backend.DiscoveryEnabled, "a failed preference write must preserve the prior opt-out");
    }

    [TestMethod]
    public void ValidationAndFailedMutationsPreserveSavedCredentialWithoutLeakingCandidate()
    {
        var backend = new FakeCredentialBackend
        {
            SavedKind = TypeSafeCredentialStorageReadKind.Value,
            SavedValue = "kept-token",
        };

        Assert.AreEqual(TypeSafeCredentialOperation.Blank, backend.Store.Save("   \r\n"));
        Assert.AreEqual(TypeSafeCredentialOperation.InvalidCharacters, backend.Store.Save("token with-space"));
        Assert.AreEqual(0, backend.WriteAttempts.Count, "invalid candidates must be rejected before secure storage");

        const string secret = "candidate-that-must-not-leak";
        backend.WriteSucceeds = false;
        var failedSave = backend.Store.Save(secret);
        Assert.AreEqual(TypeSafeCredentialOperation.Unavailable, failedSave);
        Assert.IsFalse(failedSave.ToString().Contains(secret, StringComparison.Ordinal));
        Assert.AreEqual("kept-token", backend.SavedValue, "a failed write must preserve the previous credential");

        backend.RemoveSucceeds = false;
        var failedRemove = backend.Store.Remove();
        Assert.AreEqual(TypeSafeCredentialOperation.Unavailable, failedRemove);
        Assert.IsFalse(failedRemove.ToString().Contains("kept-token", StringComparison.Ordinal));
        Assert.AreEqual("kept-token", backend.SavedValue, "a failed removal must preserve the previous credential");
    }

    private sealed class FakeCredentialBackend
    {
        internal TypeSafeCredentialStorageReadKind SavedKind { get; set; } = TypeSafeCredentialStorageReadKind.Missing;
        internal string? SavedValue { get; set; }
        internal string? EnvironmentValue { get; set; }
        internal bool DiscoveryEnabled { get; set; } = true;
        internal bool WriteSucceeds { get; set; } = true;
        internal bool RemoveSucceeds { get; set; } = true;
        internal bool DiscoveryWriteSucceeds { get; set; } = true;
        internal int DiscoveryReadCount { get; private set; }
        internal int EnvironmentReadCount { get; private set; }
        internal int RemoveAttemptCount { get; private set; }
        internal List<string> WriteAttempts { get; } = [];

        internal TypeSafeCredentialStore Store => new(
            () => new TypeSafeCredentialStorageRead(SavedKind, SavedValue),
            candidate =>
            {
                WriteAttempts.Add(candidate);
                if (!WriteSucceeds)
                    return false;
                SavedKind = TypeSafeCredentialStorageReadKind.Value;
                SavedValue = candidate;
                return true;
            },
            () =>
            {
                RemoveAttemptCount++;
                if (!RemoveSucceeds)
                    return false;
                SavedKind = TypeSafeCredentialStorageReadKind.Missing;
                SavedValue = null;
                return true;
            },
            () =>
            {
                EnvironmentReadCount++;
                return EnvironmentValue;
            },
            () =>
            {
                DiscoveryReadCount++;
                return DiscoveryEnabled;
            },
            enabled =>
            {
                if (!DiscoveryWriteSucceeds)
                    return false;
                DiscoveryEnabled = enabled;
                return true;
            }
        );
    }
}
