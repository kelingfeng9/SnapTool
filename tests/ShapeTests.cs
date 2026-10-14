using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace SnapTool
{
    internal static class ShapeTests
    {
        internal static void Run(Action<bool, string> check, string outputFolder)
        {
            Directory.CreateDirectory(outputFolder);
            CaptureShape[] expected = { CaptureShape.Rectangle, CaptureShape.Circle,
                CaptureShape.Triangle, CaptureShape.Pentagon, CaptureShape.Hexagon, CaptureShape.Polygon };
            Array values = Enum.GetValues(typeof(CaptureShape));
            bool orderMatches = values.Length == expected.Length;
            for (int i = 0; orderMatches && i < expected.Length; i++)
                orderMatches = (CaptureShape)values.GetValue(i) == expected[i];
            check(orderMatches, "shape order starts with rectangle then circle");

            using (Bitmap source = CreateSource())
            {
                Rectangle bounds = new Rectangle(30, 25, 160, 100);
                TestRectangle(check, source, bounds);
                TestCircle(check, source, bounds, outputFolder);
                foreach (CaptureShape shape in new[] { CaptureShape.Triangle, CaptureShape.Pentagon, CaptureShape.Hexagon })
                    TestRegularPolygon(check, source, bounds, shape);
                TestConcavePolygon(check, source);
                TestAnnotationClip(check, source, bounds);
                TestSourceClip(check, source);
                WritePreview(check, source, outputFolder);
            }
        }

        private static Bitmap CreateSource()
        {
            Bitmap image = new Bitmap(240, 180, PixelFormat.Format32bppArgb);
            for (int y = 0; y < image.Height; y++)
                for (int x = 0; x < image.Width; x++)
                    image.SetPixel(x, y, Color.FromArgb(255, 40 + x * 180 / image.Width,
                        45 + y * 165 / image.Height, 210 - x * 95 / image.Width));
            using (Graphics g = Graphics.FromImage(image))
            using (Pen pen = new Pen(Color.FromArgb(140, Color.White), 2))
            using (Font font = new Font(FontFamily.GenericSansSerif, 20, FontStyle.Bold))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.DrawEllipse(pen, 70, 25, 90, 90);
                g.DrawLine(pen, 0, 130, 240, 40);
                g.DrawString("SNAP", font, Brushes.White, 73, 73);
            }
            return image;
        }

        private static void TestRectangle(Action<bool, string> check, Bitmap source, Rectangle bounds)
        {
            using (GraphicsPath path = SelectionGeometry.CreatePath(CaptureShape.Rectangle, bounds, null))
                check(path.GetBounds() == (RectangleF)bounds, "rectangle path preserves selection bounds");
            using (Bitmap result = SelectionGeometry.Render(source, bounds, CaptureShape.Rectangle, null, null))
            {
                check(result != null && result.Size == bounds.Size, "rectangle keeps original output dimensions");
                bool same = result != null;
                for (int y = 0; same && y < bounds.Height; y++)
                    for (int x = 0; same && x < bounds.Width; x++)
                        same = result.GetPixel(x, y).ToArgb() == source.GetPixel(bounds.X + x, bounds.Y + y).ToArgb();
                check(same, "rectangle preserves every source pixel exactly");
            }
            check(SelectionGeometry.Contains(CaptureShape.Rectangle, bounds, null, new Point(31, 26)),
                "rectangle contains an interior point");
            check(!SelectionGeometry.Contains(CaptureShape.Rectangle, bounds, null, new Point(29, 26)),
                "rectangle rejects a point outside its bounds");
        }

        private static void TestCircle(Action<bool, string> check, Bitmap source, Rectangle bounds, string outputFolder)
        {
            using (GraphicsPath path = SelectionGeometry.CreatePath(CaptureShape.Circle, bounds, null))
            {
                RectangleF circle = path.GetBounds();
                check(Near(circle.Width, 100) && Near(circle.Height, 100), "circle is inscribed with equal width and height");
                check(Near(circle.X, bounds.X + 30) && Near(circle.Y, bounds.Y), "circle is centered inside a wide drag selection");
            }
            check(SelectionGeometry.Contains(CaptureShape.Circle, bounds, null, new Point(110, 75)),
                "circle contains its center");
            check(!SelectionGeometry.Contains(CaptureShape.Circle, bounds, null, new Point(35, 75)),
                "circle excludes wide-selection padding");
            using (Bitmap result = SelectionGeometry.Render(source, bounds, CaptureShape.Circle, null, null))
            {
                check(result != null && result.Size == bounds.Size, "circle retains selection canvas dimensions");
                check(result.GetPixel(80, 50).A == 255, "circle center stays opaque");
                check(result.GetPixel(0, 0).A == 0 && result.GetPixel(159, 99).A == 0,
                    "circle output corners are transparent");
                check(result.GetPixel(15, 50).A == 0 && result.GetPixel(145, 50).A == 0,
                    "circle wide-selection padding stays transparent");
                bool edgeCoverage = false;
                for (int y = 0; !edgeCoverage && y < result.Height; y++)
                    for (int x = 0; !edgeCoverage && x < result.Width; x++)
                    {
                        int alpha = result.GetPixel(x, y).A;
                        edgeCoverage = alpha > 0 && alpha < 255;
                    }
                check(edgeCoverage, "circle edge has antialiased transparency coverage");

                string pngPath = Path.Combine(outputFolder, "circle-transparent.png");
                result.Save(pngPath, ImageFormat.Png);
                using (Bitmap decoded = new Bitmap(pngPath))
                {
                    check(decoded.Size == result.Size && decoded.GetPixel(0, 0).A == 0,
                        "PNG round trip keeps dimensions and transparent corners");
                    check(decoded.GetPixel(80, 50).ToArgb() == result.GetPixel(80, 50).ToArgb(),
                        "PNG round trip keeps opaque source colors");
                }
                using (Bitmap opaque = SelectionGeometry.CreateOpaque(result, Color.White))
                {
                    check(opaque.Size == result.Size && opaque.GetPixel(0, 0).ToArgb() == Color.White.ToArgb(),
                        "opaque export fills transparent regions with white");
                    check(opaque.GetPixel(80, 50).ToArgb() == result.GetPixel(80, 50).ToArgb(),
                        "opaque export preserves opaque source colors");
                    string jpegPath = Path.Combine(outputFolder, "circle-white.jpg");
                    string bmpPath = Path.Combine(outputFolder, "circle-white.bmp");
                    opaque.Save(jpegPath, ImageFormat.Jpeg);
                    opaque.Save(bmpPath, ImageFormat.Bmp);
                    using (Bitmap decoded = new Bitmap(jpegPath))
                    {
                        Color corner = decoded.GetPixel(0, 0);
                        check(corner.A == 255 && corner.R >= 245 && corner.G >= 245 && corner.B >= 245,
                            "JPEG round trip has white opaque background");
                    }
                    using (Bitmap decoded = new Bitmap(bmpPath))
                        check(decoded.GetPixel(0, 0).ToArgb() == Color.White.ToArgb(),
                            "BMP round trip has white opaque background");
                }
                check(result.GetPixel(0, 0).A == 0, "opaque conversion leaves original transparency unchanged");
            }
        }

        private static void TestRegularPolygon(Action<bool, string> check, Bitmap source, Rectangle bounds, CaptureShape shape)
        {
            int vertices = shape == CaptureShape.Triangle ? 3 : shape == CaptureShape.Pentagon ? 5 : 6;
            using (GraphicsPath path = SelectionGeometry.CreatePath(shape, bounds, null))
            {
                check(path.PointCount == vertices, shape + " path has the requested number of vertices");
                check(path.IsVisible(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2),
                    shape + " path contains its center");
            }
            using (Bitmap result = SelectionGeometry.Render(source, bounds, shape, null, null))
            {
                check(result != null && result.Size == bounds.Size, shape + " keeps selection canvas dimensions");
                check(result.GetPixel(80, 50).A == 255 && result.GetPixel(0, 0).A == 0,
                    shape + " has opaque center and transparent outside corner");
            }
            check(!SelectionGeometry.Contains(shape, bounds, null, bounds.Location),
                shape + " does not hit-test the empty outside corner");
        }

        private static void TestConcavePolygon(Action<bool, string> check, Bitmap source)
        {
            Rectangle bounds = new Rectangle(30, 30, 150, 120);
            List<Point> points = new List<Point> { new Point(30, 30), new Point(180, 30),
                new Point(180, 70), new Point(90, 70), new Point(90, 150), new Point(30, 150) };
            using (GraphicsPath path = SelectionGeometry.CreatePath(CaptureShape.Polygon, bounds, points))
                check(path.PointCount == points.Count, "free polygon preserves concave user vertices");
            check(SelectionGeometry.Contains(CaptureShape.Polygon, bounds, points, new Point(60, 110)),
                "concave polygon includes its vertical arm");
            check(!SelectionGeometry.Contains(CaptureShape.Polygon, bounds, points, new Point(120, 110)),
                "concave polygon excludes its notch");
            using (Bitmap result = SelectionGeometry.Render(source, bounds, CaptureShape.Polygon, points, null))
            {
                check(result.GetPixel(30, 80).A == 255 && result.GetPixel(90, 80).A == 0,
                    "concave polygon mask includes the arm and leaves its notch transparent");
                check(result.GetPixel(100, 20).ToArgb() == source.GetPixel(130, 50).ToArgb(),
                    "free polygon uses source coordinates without shifting pixels");
            }
            List<Point> oversized = new List<Point> { new Point(0, 0), new Point(230, 0),
                new Point(230, 170), new Point(0, 170) };
            check(!SelectionGeometry.Contains(CaptureShape.Polygon, bounds, oversized, new Point(10, 10)),
                "polygon hit-testing respects selection bounds even for oversized vertices");
        }

        private static void TestAnnotationClip(Action<bool, string> check, Bitmap source, Rectangle bounds)
        {
            Color original = source.GetPixel(110, 75);
            using (Bitmap result = SelectionGeometry.Render(source, bounds, CaptureShape.Triangle, null,
                delegate(Graphics g) { g.FillRectangle(Brushes.Red, bounds); }))
            {
                check(result.GetPixel(80, 50).ToArgb() == Color.Red.ToArgb(),
                    "annotations use absolute source coordinates");
                check(result.GetPixel(0, 0).A == 0, "annotations are clipped to the selected shape");
            }
            check(source.GetPixel(110, 75).ToArgb() == original.ToArgb(), "annotation rendering leaves source bitmap untouched");
        }

        private static void TestSourceClip(Action<bool, string> check, Bitmap source)
        {
            using (Bitmap result = SelectionGeometry.Render(source, new Rectangle(-20, -10, 80, 60),
                CaptureShape.Rectangle, null, null))
            {
                check(result != null && result.Size == new Size(60, 50), "negative source bounds intersect bitmap extent");
                check(result.GetPixel(0, 0).ToArgb() == source.GetPixel(0, 0).ToArgb(),
                    "source clipping starts at the correct source pixel");
            }
            using (Bitmap result = SelectionGeometry.Render(source, new Rectangle(220, 160, 80, 60),
                CaptureShape.Rectangle, null, null))
                check(result != null && result.Size == new Size(20, 20), "right and bottom source bounds are clipped");
            using (Bitmap result = SelectionGeometry.Render(source, new Rectangle(300, 300, 40, 40),
                CaptureShape.Circle, null, null))
                check(result == null, "fully out-of-range selection returns no output");
            using (Bitmap result = SelectionGeometry.Render(source, new Rectangle(10, 10, 0, 30),
                CaptureShape.Rectangle, null, null))
                check(result == null, "zero-width selection returns no output");
        }

        private static bool Near(float actual, float expected)
        {
            return Math.Abs(actual - expected) < 0.05f;
        }

        private static void WritePreview(Action<bool, string> check, Bitmap source, string outputFolder)
        {
            const int cellWidth = 250, cellHeight = 200;
            CaptureShape[] shapes = { CaptureShape.Rectangle, CaptureShape.Circle, CaptureShape.Triangle,
                CaptureShape.Pentagon, CaptureShape.Hexagon, CaptureShape.Polygon };
            string[] names = { "矩形（默认）", "圆形", "三角形", "五边形", "六边形", "自由多边形" };
            Rectangle selection = new Rectangle(30, 25, 160, 100);
            List<Point> polygon = new List<Point> { new Point(35, 30), new Point(180, 30),
                new Point(170, 80), new Point(110, 70), new Point(115, 120), new Point(45, 120) };
            using (Bitmap preview = new Bitmap(cellWidth * 3, cellHeight * 2 + 52))
            using (Graphics g = Graphics.FromImage(preview))
            using (Font header = new Font("Microsoft YaHei", 16, FontStyle.Bold))
            using (Font label = new Font("Microsoft YaHei", 12, FontStyle.Regular))
            using (Brush light = new SolidBrush(Color.FromArgb(239, 242, 248)))
            using (Brush dark = new SolidBrush(Color.FromArgb(212, 219, 230)))
            using (Brush ink = new SolidBrush(Color.FromArgb(37, 48, 72)))
            {
                g.Clear(Color.White);
                g.DrawString("SnapTool · 形状截图 / 透明 PNG", header, ink, 18, 10);
                for (int i = 0; i < shapes.Length; i++)
                {
                    int left = (i % 3) * cellWidth + 12, top = (i / 3) * cellHeight + 54;
                    Rectangle checker = new Rectangle(left, top, cellWidth - 24, 140);
                    for (int y = checker.Top; y < checker.Bottom; y += 10)
                        for (int x = checker.Left; x < checker.Right; x += 10)
                            g.FillRectangle((((x - checker.Left) / 10 + (y - checker.Top) / 10) % 2 == 0) ? light : dark,
                                x, y, Math.Min(10, checker.Right - x), Math.Min(10, checker.Bottom - y));
                    using (Bitmap cutout = SelectionGeometry.Render(source, selection, shapes[i],
                        shapes[i] == CaptureShape.Polygon ? polygon : null, null))
                        g.DrawImageUnscaled(cutout, left + (checker.Width - cutout.Width) / 2,
                            top + (checker.Height - cutout.Height) / 2);
                    g.DrawString(names[i], label, ink, left + 8, top + 150);
                }
                string path = Path.Combine(outputFolder, "shapes-preview.png");
                preview.Save(path, ImageFormat.Png);
                using (Bitmap decoded = new Bitmap(path))
                    check(decoded.Width == 750 && decoded.Height == 452, "shape preview is saved and readable");
            }
        }
    }
}
