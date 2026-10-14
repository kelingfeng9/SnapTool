using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace SnapTool
{
    internal static class AnnotationGeometry
    {
        internal static RectangleF Bounds(Annotation item)
        {
            if (item.BoundsValid) return item.CachedBounds;
            float left = Math.Min(item.P1.X, item.P2.X), top = Math.Min(item.P1.Y, item.P2.Y);
            float right = Math.Max(item.P1.X, item.P2.X), bottom = Math.Max(item.P1.Y, item.P2.Y);
            float pad = Math.Max(6, item.Width * 3 + 3);
            if (item.Tool == Tool.Pen || item.Tool == Tool.Highlight)
            {
                left = right = item.P1.X; top = bottom = item.P1.Y;
                if (item.Points != null)
                    foreach (Point p in item.Points)
                    { left = Math.Min(left, p.X); top = Math.Min(top, p.Y); right = Math.Max(right, p.X); bottom = Math.Max(bottom, p.Y); }
            }
            else if (item.Tool == Tool.Text)
            {
                using (var font = new Font("Microsoft YaHei UI", item.FontSize, FontStyle.Bold, GraphicsUnit.Pixel))
                {
                    Size size = TextRenderer.MeasureText(item.Text ?? "", font, Size.Empty, TextFormatFlags.NoPadding);
                    left = item.P1.X; top = item.P1.Y; right = left + size.Width; bottom = top + size.Height;
                }
                pad = Math.Max(4, item.FontSize / 7f + 3);
            }
            else if (item.Tool == Tool.Number)
            {
                float radius = Math.Max(20, (int)(item.Width * 9)) / 2f;
                left = item.P1.X - radius; top = item.P1.Y - radius;
                right = item.P1.X + radius; bottom = item.P1.Y + radius; pad = 3;
            }
            item.CachedBounds = RectangleF.FromLTRB(left - pad, top - pad, right + pad, bottom + pad);
            item.BoundsValid = true;
            return item.CachedBounds;
        }

        internal static bool HitTest(Annotation item, Point point)
        {
            if (!Bounds(item).Contains(point)) return false;
            float tolerance = Math.Max(7, item.Width / 2f + 4);
            switch (item.Tool)
            {
                case Tool.Text:
                case Tool.Number: return true;
                case Tool.Mosaic: return Normalized(item.P1, item.P2).Contains(point);
                case Tool.Rect:
                case Tool.Ellipse:
                    Rectangle r = Normalized(item.P1, item.P2);
                    if (r.Width < 1 || r.Height < 1) return false;
                    using (var path = new GraphicsPath())
                    using (var pen = new Pen(Color.Black, tolerance * 2))
                    {
                        if (item.Tool == Tool.Rect) path.AddRectangle(r); else path.AddEllipse(r);
                        return item.Filled ? path.IsVisible(point) : path.IsOutlineVisible(point, pen);
                    }
                case Tool.Pen:
                case Tool.Highlight:
                    if (item.Tool == Tool.Highlight) tolerance = Math.Max(tolerance, item.Width * 2.5f + 4);
                    if (item.Points == null || item.Points.Count == 0) return false;
                    if (item.Points.Count == 1) return Distance(point, item.Points[0], item.Points[0]) <= tolerance;
                    for (int i = 1; i < item.Points.Count; i++)
                        if (Distance(point, item.Points[i - 1], item.Points[i]) <= tolerance) return true;
                    return false;
                default: return Distance(point, item.P1, item.P2) <= tolerance;
            }
        }

        internal static Rectangle Normalized(Point start, Point end)
        {
            return new Rectangle(Math.Min(start.X, end.X), Math.Min(start.Y, end.Y), Math.Abs(start.X - end.X), Math.Abs(start.Y - end.Y));
        }

        private static double Distance(Point p, Point a, Point b)
        {
            double dx = b.X - a.X, dy = b.Y - a.Y;
            double length = dx * dx + dy * dy;
            double fraction = length == 0 ? 0 : Math.Max(0, Math.Min(1, ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / length));
            dx = p.X - a.X - fraction * dx; dy = p.Y - a.Y - fraction * dy;
            return Math.Sqrt(dx * dx + dy * dy);
        }

        internal static void Translate(Annotation item, Point delta)
        {
            item.P1.Offset(delta); item.P2.Offset(delta);
            if (item.Points != null)
                for (int i = 0; i < item.Points.Count; i++)
                { Point point = item.Points[i]; point.Offset(delta); item.Points[i] = point; }
            item.InvalidateCache();
        }
    }
}
