using System.Globalization;
using System.Windows;

namespace Envelope.Windows.Services;

public interface ILocalizationService
{
    event EventHandler? LanguageChanged;

    string CurrentCulture { get; }

    string GetString(string resourceKey);

    void ApplyCulture(string cultureName);
}

public sealed class LocalizationService : ILocalizationService
{
    private const string DictionaryMarker = "Resources/Strings.";

    public static LocalizationService Current { get; } = new();

    public event EventHandler? LanguageChanged;

    public string CurrentCulture { get; private set; } = "zh-CN";

    private LocalizationService()
    {
    }

    public string GetString(string resourceKey) =>
        Application.Current.TryFindResource(resourceKey) as string ?? resourceKey;

    public void ApplyCulture(string cultureName)
    {
        var normalized = cultureName.StartsWith("zh", StringComparison.OrdinalIgnoreCase)
            ? "zh-CN"
            : "en-US";
        var dictionaries = Application.Current.Resources.MergedDictionaries;
        var replacement = new ResourceDictionary
        {
            Source = new Uri($"Resources/Strings.{normalized}.xaml", UriKind.Relative),
        };

        var index = FindDictionaryIndex(dictionaries, DictionaryMarker);
        if (index >= 0)
        {
            dictionaries[index] = replacement;
        }
        else
        {
            dictionaries.Add(replacement);
        }

        CurrentCulture = normalized;
        var culture = CultureInfo.GetCultureInfo(normalized);
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        LanguageChanged?.Invoke(this, EventArgs.Empty);
    }

    private static int FindDictionaryIndex(IList<ResourceDictionary> dictionaries, string marker)
    {
        for (var i = 0; i < dictionaries.Count; i++)
        {
            if (dictionaries[i].Source?.OriginalString.Contains(marker, StringComparison.OrdinalIgnoreCase) == true)
            {
                return i;
            }
        }

        return -1;
    }
}
