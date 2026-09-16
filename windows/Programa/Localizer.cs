using Microsoft.Windows.ApplicationModel.Resources;

namespace Programa;

internal static class Localizer
{
    private static readonly ResourceLoader Loader = new();
    public static string Get(string key) => Loader.GetString(key);
}
