using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace SnapTool
{
    // The order is also the order used by the selection menu.
    internal enum CaptureShape { Rectangle, Circle, Triangle, Pentagon, Hexagon, Polygon }

    internal static class SelectionGeometry
    {
        /// <summary>Returns a caller-owned path in absolute screenshot coordinates.</summary>
        internal static GraphicsPath CreatePath(CaptureShape shape, Rectangle bounds, IList<Point> polygonPoints)
        {
            var path = new GraphicsPath(FillMode.Alternate);
            if (bounds.Width <= 0 || bounds.Height <= 0) return path;

            float left = bounds.X;
            float top = bounds.Y;
            float width = bounds.Width;
            float height = bounds.Height;
            switch (shape)
            {
                case CaptureShape.Circle:
                    float diameter = Math.Min(width, height);
                    path.AddEllipse(left + (width - diameter) / 2f, top + (height - diameter) / 2f, diameter, diameter);
                    break;
                case CaptureShape.Triangle:
                    path.AddPolygon(new PointF[]
                    {
                        new PointF(left + width / 2f, top),
                        new PointF(left + width, top + height),
                        new PointF(left, top + height)
                    });
                    break;
                case CaptureShape.Pentagon:
                case CaptureShape.Hexagon:
                    // A single radius preserves regular polygons in a non-square selection.
                    int count = shape == CaptureShape.Pentagon ? 5 : 6;
                    var vertices = new PointF[count];
                    double radius = Math.Min(width, height) / 2.0;
                    double centerX = left + width / 2.0;
                    double centerY = top + height / 2.0;
                    for (int i = 0; i < count; i++)
                    {
                        double angle = -Math.PI / 2.0 + i * 2.0 * Math.PI / count;
                        vertices[i] = new PointF((float)(centerX + radius * Math.Cos(angle)), (float)(centerY + radius * Math.Sin(angle)));
                    }
                    path.AddPolygon(vertices);
                    break;
                case CaptureShape.Polygon:
                    if (polygonPoints != null && polygonPoints.Count >= 3)
                    {
                        var points = new Point[polygonPoints.Count];
                        for (int i = 0; i < points.Length; i++) points[i] = polygonPoints[i];
                        path.AddPolygon(points);
                    }
                    break;
                default:
                    path.AddRectangle(new RectangleF(left, top, width, height));
                    break;
            }
            return path;
        }

        internal static bool Contains(CaptureShape shape, Rectangle bounds, IList<Point> polygonPoints, Point point)
        {
            if (!bounds.Contains(point)) return false;
            using (var path = CreatePath(shape, bounds, polygonPoints)) return path.IsVisible(point);
        }

        /// <summary>
        /// Crops to the source/bounds intersection, then masks both screenshot and annotations.
        /// The callback draws in absolute screenshot coordinates. Empty crops return null.
        /// </summary>
        internal static Bitmap Render(Bitmap source, Rectangle bounds, CaptureShape shape, IList<Point> polygonPoints, Action<Graphics> drawAnnotations)
        {
            if (source == null) throw new ArgumentNullException("source");
            if (bounds.Width <= 0 || bounds.Height <= 0) return null;
            Rectangle crop = Rectangle.Intersect(new Rectangle(Point.Empty, source.Size), bounds);
            if (crop.Width <= 0 || crop.Height <= 0) return null;

            // Clone avoids interpolation and preserves screenshot pixels for rectangle captures.
            Bitmap output = source.Clone(crop, PixelFormat.Format32bppArgb);
            try
            {
                if (drawAnnotations != null)
                {
                    using (Graphics graphics = Graphics.FromImage(output))
                    {
                        graphics.SmoothingMode = SmoothingMode.AntiAlias;
                        graphics.TranslateTransform(-crop.X, -crop.Y);
                        drawAnnotations(graphics);
                    }
                }

                if (shape != CaptureShape.Rectangle)
                {
                    using (var mask = new Bitmap(crop.Width, crop.Height, PixelFormat.Format32bppArgb))
                    {
                        using (Graphics graphics = Graphics.FromImage(mask))
                        using (GraphicsPath path = CreatePath(shape, bounds, polygonPoints))
                        {
                            graphics.Clear(Color.Transparent);
                            graphics.SmoothingMode = SmoothingMode.AntiAlias;
                            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                            graphics.TranslateTransform(-crop.X, -crop.Y);
                            graphics.FillPath(Brushes.White, path);
                        }
                        // A Graphics clip alone has hard pixel boundaries. Its separately rendered
                        // antialiased mask provides fractional alpha for every curved/sloped edge.
                        ApplyAlphaMask(output, mask);
                    }
                }
                return output;
            }
            catch
            {
                output.Dispose();
                throw;
            }
        }

        /// <summary>Flattens a transparent screenshot onto an opaque background for JPEG/BMP.</summary>
        internal static Bitmap CreateOpaque(Bitmap source, Color background)
        {
            if (source == null) throw new ArgumentNullException("source");
            var output = new Bitmap(source.Width, source.Height, PixelFormat.Format24bppRgb);
            try
            {
                using (Graphics graphics = Graphics.FromImage(output))
                {
                    graphics.Clear(Color.FromArgb(255, background.R, background.G, background.B));
                    graphics.DrawImageUnscaled(source, 0, 0);
                }
                return output;
            }
            catch
            {
                output.Dispose();
                throw;
            }
        }

        private static void ApplyAlphaMask(Bitmap output, Bitmap mask)
        {
            Rectangle area = new Rectangle(Point.Empty, output.Size);
            BitmapData outputData = null;
            BitmapData maskData = null;
            try
            {
                outputData = output.LockBits(area, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
                maskData = mask.LockBits(area, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                int rowBytes = checked(output.Width * 4);
                var pixels = new byte[rowBytes];
                var coverage = new byte[rowBytes];
                for (int y = 0; y < output.Height; y++)
                {
                    IntPtr outputRow = IntPtr.Add(outputData.Scan0, y * outputData.Stride);
                    IntPtr maskRow = IntPtr.Add(maskData.Scan0, y * maskData.Stride);
                    Marshal.Copy(outputRow, pixels, 0, rowBytes);
                    Marshal.Copy(maskRow, coverage, 0, rowBytes);
                    for (int x = 0; x < rowBytes; x += 4)
                    {
                        int alpha = (pixels[x + 3] * coverage[x + 3] + 127) / 255;
                        pixels[x + 3] = (byte)alpha;
                        if (alpha == 0) pixels[x] = pixels[x + 1] = pixels[x + 2] = 0;
                    }
                    Marshal.Copy(pixels, 0, outputRow, rowBytes);
                }
            }
            finally
            {
                if (maskData != null) mask.UnlockBits(maskData);
                if (outputData != null) output.UnlockBits(outputData);
            }
        }
    }
}
