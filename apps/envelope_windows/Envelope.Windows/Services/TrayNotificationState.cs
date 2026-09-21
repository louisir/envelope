using Envelope.Windows.Models;

namespace Envelope.Windows.Services;

/// <summary>Tracks unread transitions, not total-count deltas, so a read in one
/// conversation cannot conceal a new arrival in another. Never retains plaintext.</summary>
public sealed class TrayNotificationState
{
    private Dictionary<string, int>? _previous;
    public DateTimeOffset? QuietUntil { get; set; }
    public bool IsQuiet(DateTimeOffset now) => QuietUntil is { } end && end > now;

    public string? Observe(IReadOnlyList<ConversationUiModel> conversations, DateTimeOffset now)
    {
        var target = _previous is null ? null : conversations
            .Where(item => item.UnreadCount > _previous.GetValueOrDefault(item.Id))
            .OrderByDescending(item => item.LastActivity)
            .Select(item => item.Id).FirstOrDefault();
        _previous = conversations.ToDictionary(item => item.Id, item => item.UnreadCount, StringComparer.Ordinal);
        return IsQuiet(now) ? null : target;
    }
}
