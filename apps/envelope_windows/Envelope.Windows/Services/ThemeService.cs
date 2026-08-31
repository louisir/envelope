using System.Windows;
using Microsoft.Win32;

namespace Envelope.Windows.Services;

public enum ThemePreference
{
    System,
    Light,
    Dark,
}

public interface IThemeService
{
    ThemePreference CurrentPreference { get; }

    void ApplyTheme(ThemePreference preference);
}

public sealed class ThemeService : IThemeService
{
    private const string DictionaryMarker = "Resources/Themes/";

    public static ThemeService Current { get; } = new();

    public ThemePreference CurrentPreference { get; private set; } = ThemePreference.System;

    private ThemeService()
    {
    }

    public void ApplyTheme(ThemePreference preference)
    {
        CurrentPreference = preference;
        var effective = preference == ThemePreference.System
            ? (IsSystemDarkMode() ? ThemePreference.Dark : ThemePreference.Light)
            : preference;
        var themeName = effective == ThemePreference.Dark ? "Dark" : "Light";
        var dictionaries = Application.Current.Resources.MergedDictionaries;
        var replacement = new ResourceDictionary
        {
            Source = new Uri($"Resources/Themes/{themeName}.xaml", UriKind.Relative),
        };

        var index = FindDictionaryIndex(dictionaries);
        if (index >= 0)
        {
            dictionaries[index] = replacement;
        }
        else
        {
            dictionaries.Insert(0, replacement);
        }
    }

    private static int FindDictionaryIndex(IList<ResourceDictionary> dictionaries)
    {
        for (var i = 0; i < dictionaries.Count; i++)
        {
            if (dictionaries[i].Source?.OriginalString.Contains(DictionaryMarker, StringComparison.OrdinalIgnoreCase) == true)
            {
                return i;
            }
        }

        return -1;
    }

    private static bool IsSystemDarkMode()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch
        {
            return false;
        }
    }
}
