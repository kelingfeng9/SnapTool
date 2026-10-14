using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace SnapTool
{
    /// <summary>Persist image data immediately, including formats that retain alpha.</summary>
    internal static class ImageClipboard
    {
        private const uint CfBitmap = 2;
        private const uint CfDibV5 = 17;
        private const uint GmemMoveable = 0x0002;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool OpenClipboard(IntPtr owner);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EmptyClipboard();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseClipboard();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetClipboardData(uint format, IntPtr memory);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint RegisterClipboardFormat(string format);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalFree(IntPtr memory);
        [DllImport("gdi32.dll")]
        private static extern bool DeleteObject(IntPtr value);

        internal static bool SetImageSafe(Image image, IntPtr owner)
        {
            if (image == null || owner == IntPtr.Zero) return false;
            try
            {
                uint pngFormat = RegisterClipboardFormat("PNG");
                if (pngFormat == 0) return false;
                using (var argb = CreateArgbBitmap(image))
                using (var compatible = CreateCompatibleBitmap(argb))
                {
                    byte[] png;
                    using (var stream = new MemoryStream())
                    {
                        argb.Save(stream, ImageFormat.Png);
                        png = stream.ToArray();
                    }
                    byte[] dib = CreateDibV5(argb);
                    for (int attempt = 0; attempt < 5; attempt++)
                    {
                        IntPtr pngMemory = IntPtr.Zero, dibMemory = IntPtr.Zero, bitmap = IntPtr.Zero;
                        bool opened = false;
                        try
                        {
                            // Prepare every representation before replacing existing contents.
                            pngMemory = AllocateBytes(png);
                            dibMemory = AllocateBytes(dib);
                            bitmap = compatible.GetHbitmap();
                            opened = OpenClipboard(owner);
                            if (opened && EmptyClipboard())
                            {
                                bool dibSet = Transfer(CfDibV5, ref dibMemory);
                                bool bitmapSet = Transfer(CfBitmap, ref bitmap);
                                bool pngSet = Transfer(pngFormat, ref pngMemory);
                                if (dibSet && bitmapSet && pngSet) return true;
                            }
                        }
                        catch (ExternalException) { }
                        finally
                        {
                            if (opened) CloseClipboard();
                            // SetClipboardData owns successfully transferred handles, even
                            // after this process exits. Only failed transfers are ours to free.
                            if (pngMemory != IntPtr.Zero) GlobalFree(pngMemory);
                            if (dibMemory != IntPtr.Zero) GlobalFree(dibMemory);
                            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
                        }
                        if (attempt < 4) System.Threading.Thread.Sleep(30);
                    }
                }
            }
            catch (Exception) { }
            return false;
        }

        private static bool Transfer(uint format, ref IntPtr memory)
        {
            if (SetClipboardData(format, memory) == IntPtr.Zero) return false;
            memory = IntPtr.Zero;
            return true;
        }

        private static IntPtr AllocateBytes(byte[] bytes)
        {
            IntPtr memory = GlobalAlloc(GmemMoveable, new UIntPtr((uint)bytes.Length));
            if (memory == IntPtr.Zero) throw new ExternalException("Unable to allocate clipboard memory.");
            IntPtr address = GlobalLock(memory);
            if (address == IntPtr.Zero)
            {
                GlobalFree(memory);
                throw new ExternalException("Unable to lock clipboard memory.");
            }
            bool copied = false;
            try { Marshal.Copy(bytes, 0, address, bytes.Length); copied = true; }
            finally
            {
                GlobalUnlock(memory);
                if (!copied) GlobalFree(memory);
            }
            return memory;
        }

        internal static Bitmap CreateArgbBitmap(Image image)
        {
            var bitmap = image as Bitmap;
            if (bitmap != null && bitmap.PixelFormat == PixelFormat.Format32bppArgb)
                return bitmap.Clone(new Rectangle(0, 0, bitmap.Width, bitmap.Height), PixelFormat.Format32bppArgb);
            var result = new Bitmap(image.Width, image.Height, PixelFormat.Format32bppArgb);
            try
            {
                using (var graphics = Graphics.FromImage(result))
                {
                    graphics.CompositingMode = CompositingMode.SourceCopy;
                    graphics.DrawImageUnscaled(image, 0, 0);
                }
                return result;
            }
            catch { result.Dispose(); throw; }
        }

        // CF_BITMAP does not support alpha; white is the compatibility background.
        private static Bitmap CreateCompatibleBitmap(Bitmap image)
        {
            var result = new Bitmap(image.Width, image.Height, PixelFormat.Format24bppRgb);
            try
            {
                using (var graphics = Graphics.FromImage(result))
                {
                    graphics.Clear(Color.White);
                    graphics.DrawImageUnscaled(image, 0, 0);
                }
                return result;
            }
            catch { result.Dispose(); throw; }
        }

        internal static byte[] CreateDibV5(Bitmap image)
        {
            int rowBytes = checked(image.Width * 4);
            int pixelBytes = checked(rowBytes * image.Height);
            using (var stream = new MemoryStream(checked(124 + pixelBytes)))
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write(124u);                        // BITMAPV5HEADER
                writer.Write(image.Width);
                writer.Write(-image.Height);               // Top-down BGRA rows.
                writer.Write((ushort)1);
                writer.Write((ushort)32);
                writer.Write(3u);                          // BI_BITFIELDS
                writer.Write((uint)pixelBytes);
                writer.Write(0); writer.Write(0);          // Resolution.
                writer.Write(0u); writer.Write(0u);
                writer.Write(0x00ff0000u);                  // R
                writer.Write(0x0000ff00u);                  // G
                writer.Write(0x000000ffu);                  // B
                writer.Write(0xff000000u);                  // A
                writer.Write(0x73524742u);                  // LCS_sRGB
                for (int i = 0; i < 12; i++) writer.Write(0u); // Endpoints + gamma.
                writer.Write(4u);                          // LCS_GM_IMAGES
                writer.Write(0u); writer.Write(0u); writer.Write(0u);
                var bounds = new Rectangle(0, 0, image.Width, image.Height);
                BitmapData data = image.LockBits(bounds, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var row = new byte[rowBytes];
                    for (int y = 0; y < image.Height; y++)
                    {
                        Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, rowBytes);
                        writer.Write(row);
                    }
                }
                finally { image.UnlockBits(data); }
                return stream.ToArray();
            }
        }
    }
}
