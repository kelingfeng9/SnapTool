param([string]$OutputPath = 'app.ico')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('SnapToolIconArtwork' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Collections.Generic;

public static class SnapToolIconArtwork
{
    private static GraphicsPath Rounded(float x, float y, float width, float height, float radius)
    {
        var path = new GraphicsPath();
        float d = radius * 2;
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + width - d, y, d, d, 270, 90);
        path.AddArc(x + width - d, y + height - d, d, d, 0, 90);
        path.AddArc(x, y + height - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static Bitmap Render(int size)
    {
        // Supersampling makes diagonal edges readable at 16/20/24 pixels.
        using (var large = new Bitmap(size * 4, size * 4, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(large))
        {
            g.Clear(Color.Transparent);
            g.ScaleTransform(size * 4f / 256, size * 4f / 256);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var tile = Rounded(12, 12, 232, 232, 54))
            using (var gradient = new LinearGradientBrush(new Rectangle(12, 12, 232, 232),
                Color.FromArgb(21, 192, 225), Color.FromArgb(37, 87, 218), 65f))
            {
                g.FillPath(gradient, tile);
                using (var outline = new Pen(Color.FromArgb(45, 255, 255, 255), 2)) g.DrawPath(outline, tile);
            }
            using (var white = new Pen(Color.White, 17))
            {
                white.StartCap = white.EndCap = LineCap.Round;
                white.LineJoin = LineJoin.Round;
                g.DrawLines(white, new[] { new PointF(65, 104), new PointF(65, 69), new PointF(101, 69) });
                g.DrawLines(white, new[] { new PointF(154, 69), new PointF(190, 69), new PointF(190, 104) });
                g.DrawLines(white, new[] { new PointF(65, 152), new PointF(65, 187), new PointF(101, 187) });
                g.DrawLines(white, new[] { new PointF(154, 187), new PointF(190, 187), new PointF(190, 152) });
            }
            // A warm pointer communicates selecting a screen region without tiny text.
            using (var cursor = new GraphicsPath())
            {
                cursor.AddPolygon(new[] { new PointF(144, 135), new PointF(148, 197),
                    new PointF(164, 182), new PointF(179, 209), new PointF(192, 201),
                    new PointF(177, 175), new PointF(199, 173) });
                using (var border = new Pen(Color.FromArgb(27, 79, 184), 9) { LineJoin = LineJoin.Round }) g.DrawPath(border, cursor);
                using (var fill = new SolidBrush(Color.FromArgb(255, 193, 82))) g.FillPath(fill, cursor);
            }
            var result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var target = Graphics.FromImage(result))
            {
                target.CompositingMode = CompositingMode.SourceCopy;
                target.InterpolationMode = InterpolationMode.HighQualityBicubic;
                target.PixelOffsetMode = PixelOffsetMode.HighQuality;
                target.DrawImage(large, new Rectangle(0, 0, size, size), 0, 0, large.Width, large.Height, GraphicsUnit.Pixel);
            }
            return result;
        }
    }

    private static byte[] Encode(Bitmap bitmap, bool png)
    {
        using (var stream = new MemoryStream())
        {
            if (png) { bitmap.Save(stream, ImageFormat.Png); return stream.ToArray(); }
            using (var writer = new BinaryWriter(stream))
            {
                int size = bitmap.Width, maskStride = ((size + 31) / 32) * 4;
                writer.Write(40); writer.Write(size); writer.Write(size * 2);
                writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(0);
                writer.Write(size * size * 4 + maskStride * size);
                writer.Write(0); writer.Write(0); writer.Write(0); writer.Write(0);
                for (int y = size - 1; y >= 0; y--)
                    for (int x = 0; x < size; x++)
                    {
                        Color pixel = bitmap.GetPixel(x, y);
                        writer.Write(pixel.B); writer.Write(pixel.G); writer.Write(pixel.R); writer.Write(pixel.A);
                    }
                for (int y = size - 1; y >= 0; y--)
                {
                    var mask = new byte[maskStride];
                    for (int x = 0; x < size; x++) if (bitmap.GetPixel(x, y).A == 0) mask[x / 8] |= (byte)(128 >> (x % 8));
                    writer.Write(mask);
                }
                return stream.ToArray();
            }
        }
    }

    public static void WriteIcon(string path)
    {
        int[] sizes = {16, 20, 24, 32, 40, 48, 64, 96, 128, 256};
        var images = new List<byte[]>();
        foreach (int size in sizes) using (var bitmap = Render(size)) images.Add(Encode(bitmap, size == 256));
        using (var writer = new BinaryWriter(File.Create(path)))
        {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
            int offset = 6 + sizes.Length * 16;
            for (int i = 0; i < sizes.Length; i++)
            {
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                writer.Write((byte)0); writer.Write((byte)0);
                writer.Write((ushort)1); writer.Write((ushort)32);
                writer.Write(images[i].Length); writer.Write(offset); offset += images[i].Length;
            }
            foreach (var bytes in images) writer.Write(bytes);
        }
    }

    public static void WritePreviews(string folder)
    {
        Directory.CreateDirectory(folder);
        foreach (int size in new[] {16, 24, 32, 48, 64, 128, 256, 512})
            using (var bitmap = Render(size)) bitmap.Save(Path.Combine(folder, "SnapTool-logo-" + size + ".png"), ImageFormat.Png);
        using (var sheet = new Bitmap(820, 440, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(sheet))
        using (var title = new Font("Segoe UI", 24, FontStyle.Bold))
        using (var label = new Font("Segoe UI", 11))
        {
            g.Clear(Color.FromArgb(246, 248, 252));
            g.DrawString("SnapTool", title, Brushes.DarkSlateGray, 34, 20);
            using (var hero = Render(256)) g.DrawImageUnscaled(hero, 24, 95);
            int x = 330;
            foreach (int size in new[] {16, 24, 32, 48, 64})
            {
                using (var bitmap = Render(size)) g.DrawImageUnscaled(bitmap, x + (70 - size) / 2, 130 + (64 - size) / 2);
                g.DrawString(size + " px", label, Brushes.SlateGray, x + 10, 208);
                x += 88;
            }
            using (var dark = new SolidBrush(Color.FromArgb(26, 34, 52))) g.FillRectangle(dark, 318, 267, 470, 126);
            x = 330;
            foreach (int size in new[] {16, 24, 32, 48, 64})
            {
                using (var bitmap = Render(size)) g.DrawImageUnscaled(bitmap, x + (70 - size) / 2, 289 + (64 - size) / 2);
                x += 88;
            }
            sheet.Save(Path.Combine(folder, "SnapTool-icon-preview.png"), ImageFormat.Png);
        }
    }
}
'@
}
$destination = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $PSScriptRoot $OutputPath }
[SnapToolIconArtwork]::WriteIcon($destination)
[SnapToolIconArtwork]::WritePreviews((Join-Path $PSScriptRoot 'assets'))
Write-Output "Generated multi-resolution icon: $destination"
