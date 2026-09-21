using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows;
using Forms = System.Windows.Forms;

namespace Envelope.Windows.Services;

internal sealed class TrayContextMenu : Forms.ContextMenuStrip
{
    public TrayContextMenu()
    {
        Renderer = new RoundedRenderer();
        ShowImageMargin = false;
        ShowCheckMargin = true;
        Padding = new Forms.Padding(5);
        Font = System.Drawing.SystemFonts.MenuFont;
    }

    protected override void OnOpening(CancelEventArgs e)
    {
        base.OnOpening(e);
        BackColor = ThemeColor("Brush.SurfaceRaised");
        ForeColor = ThemeColor("Brush.Text");
        foreach (Forms.ToolStripItem item in Items)
            if (item is Forms.ToolStripMenuItem) item.Padding = new Forms.Padding(6, 5, 8, 5);
        UpdateRegion();
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        UpdateRegion();
    }

    private void UpdateRegion()
    {
        if (Width < 2 || Height < 2) return;
        using var outline = Rounded(new Rectangle(0, 0, Width, Height), 6f * DeviceDpi / 96);
        var previous = Region;
        Region = new Region(outline);
        previous?.Dispose();
    }

    private static Color ThemeColor(string key)
    {
        var color = ((System.Windows.Media.SolidColorBrush)Application.Current.FindResource(key)).Color;
        return Color.FromArgb(color.A, color.R, color.G, color.B);
    }

    private static GraphicsPath Rounded(Rectangle bounds, float radius)
    {
        var path = new GraphicsPath();
        var diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    private sealed class RoundedRenderer : Forms.ToolStripProfessionalRenderer
    {
        protected override void OnRenderToolStripBackground(Forms.ToolStripRenderEventArgs e)
        {
            using var brush = new SolidBrush(ThemeColor("Brush.SurfaceRaised"));
            e.Graphics.FillRectangle(brush, e.AffectedBounds);
        }

        protected override void OnRenderToolStripBorder(Forms.ToolStripRenderEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var border = Rounded(new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1), 6f * e.ToolStrip.DeviceDpi / 96);
            using var pen = new Pen(ThemeColor("Brush.Border"));
            e.Graphics.DrawPath(pen, border);
        }

        protected override void OnRenderImageMargin(Forms.ToolStripRenderEventArgs e) { }

        protected override void OnRenderMenuItemBackground(Forms.ToolStripItemRenderEventArgs e)
        {
            if (!e.Item.Selected || !e.Item.Enabled) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var shape = Rounded(new Rectangle(2, 1, e.Item.Width - 4, e.Item.Height - 2), 4f * (e.ToolStrip?.DeviceDpi ?? 96) / 96);
            using var brush = new SolidBrush(ThemeColor("Brush.AccentSoft"));
            e.Graphics.FillPath(brush, shape);
        }

        protected override void OnRenderItemText(Forms.ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = ThemeColor(!e.Item.Enabled ? "Brush.TextMuted" : e.Item.Selected ? "Brush.Accent" : "Brush.Text");
            Forms.TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, e.TextRectangle, e.TextColor, e.TextFormat);
        }

        protected override void OnRenderArrow(Forms.ToolStripArrowRenderEventArgs e)
        {
            e.ArrowColor = ThemeColor(e.Item?.Selected == true ? "Brush.Accent" : "Brush.TextMuted");
            base.OnRenderArrow(e);
        }

        protected override void OnRenderSeparator(Forms.ToolStripSeparatorRenderEventArgs e)
        {
            using var pen = new Pen(ThemeColor("Brush.Border"));
            e.Graphics.DrawLine(pen, 10, e.Item.Height / 2, e.Item.Width - 10, e.Item.Height / 2);
        }

        protected override void OnRenderItemCheck(Forms.ToolStripItemImageRenderEventArgs e)
        {
            var box = e.ImageRectangle;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(ThemeColor("Brush.Accent"), 1.6f * (e.ToolStrip?.DeviceDpi ?? 96) / 96);
            e.Graphics.DrawLines(pen, new[] {
                new PointF(box.Left + box.Width * .15f, box.Top + box.Height * .5f),
                new PointF(box.Left + box.Width * .4f, box.Top + box.Height * .75f),
                new PointF(box.Left + box.Width * .85f, box.Top + box.Height * .25f) });
        }
    }
}
