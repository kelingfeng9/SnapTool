using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SnapTool
{
    /// <summary>贴图窗口:把截图以无边框置顶窗口钉在屏幕上(类 Snipaste)。</summary>
    internal sealed class PinForm : Form
    {
        private readonly Bitmap _image;
        private readonly Region _imageRegion;
        private IntPtr _registeredHandle;
        private bool _resourcesDisposed;
        private Point _dragOrigin;
        private bool _dragging;
        private bool _topMost = true;

        public PinForm(Bitmap image, Point screenLocation)
        {
            AutoScaleMode = AutoScaleMode.None;
            _image = image;
            // Scan alpha once. Zooming transforms this cached contour instead of
            // rebuilding it during every paint or reading pixels repeatedly.
            _imageRegion = CreateImageRegion(image);

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            KeyPreview = true;
            Cursor = Cursors.SizeAll;

            // 初始大小:大图等比缩到工作区内,避免越出屏幕
            var screen = Screen.FromPoint(screenLocation).WorkingArea;
            int w = image.Width, h = image.Height;
            if (w > screen.Width || h > screen.Height)
            {
                float s = Math.Min((float)screen.Width / w, (float)screen.Height / h);
                w = Math.Max(1, (int)(w * s));
                h = Math.Max(1, (int)(h * s));
            }
            ClientSize = new Size(w, h);

            // 初始位置:紧贴截图选区,并防止越出屏幕
            int x = screenLocation.X, y = screenLocation.Y;
            if (x + Width > screen.Right) x = screen.Right - Width;
            if (y + Height > screen.Bottom) y = screen.Bottom - Height;
            if (x < screen.X) x = screen.X;
            if (y < screen.Y) y = screen.Y;
            Location = new Point(x, y);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.DrawImage(_image, 0, 0, ClientSize.Width, ClientSize.Height);
            // Draw the border after the image so it remains visible.
            if (_imageRegion == null)
                ControlPaint.DrawBorder(e.Graphics, ClientRectangle,
                    Color.FromArgb(120, 0, 0, 0), 1, ButtonBorderStyle.Solid,
                    Color.FromArgb(120, 0, 0, 0), 1, ButtonBorderStyle.Solid,
                    Color.FromArgb(120, 0, 0, 0), 1, ButtonBorderStyle.Solid,
                    Color.FromArgb(120, 0, 0, 0), 1, ButtonBorderStyle.Solid);
        }

        protected override void OnClientSizeChanged(EventArgs e)
        {
            base.OnClientSizeChanged(e);
            if (_imageRegion == null || _resourcesDisposed || ClientSize.Width < 1 || ClientSize.Height < 1) return;
            Region next = _imageRegion.Clone();
            using (var transform = new Matrix())
            {
                transform.Scale(ClientSize.Width / (float)_image.Width, ClientSize.Height / (float)_image.Height);
                next.Transform(transform);
            }
            Region previous = Region;
            Region = next;
            if (previous != null) previous.Dispose();
        }

        // A Form Region clips both rendering and hit testing: pixels outside
        // the image's silhouette show the desktop and clicks pass through.
        // A fully opaque image needs no Region and keeps its rectangular border.
        internal static Region CreateImageRegion(Bitmap image)
        {
            if (!Image.IsAlphaPixelFormat(image.PixelFormat)) return null;
            using (var argb = ImageClipboard.CreateArgbBitmap(image))
            using (var path = new GraphicsPath(FillMode.Winding))
            {
                int rowBytes = checked(argb.Width * 4);
                var row = new byte[rowBytes];
                bool hasTransparency = false;
                BitmapData data = argb.LockBits(new Rectangle(0, 0, argb.Width, argb.Height),
                    ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    for (int y = 0; y < argb.Height; y++)
                    {
                        Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, rowBytes);
                        int start = -1;
                        for (int x = 0; x < argb.Width; x++)
                        {
                            byte alpha = row[x * 4 + 3];
                            if (alpha != 255) hasTransparency = true;
                            if (alpha != 0 && start < 0) start = x;
                            if (alpha == 0 && start >= 0)
                            {
                                path.AddRectangle(new Rectangle(start, y, x - start, 1));
                                start = -1;
                            }
                        }
                        if (start >= 0) path.AddRectangle(new Rectangle(start, y, argb.Width - start, 1));
                    }
                }
                finally { argb.UnlockBits(data); }
                return hasTransparency ? new Region(path) : null;
            }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                // 黑色细边,无标题
                return cp;
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                _dragging = true;
                _dragOrigin = e.Location;
                Cursor = Cursors.SizeAll;
            }
            base.OnMouseDown(e);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_dragging)
            {
                Location = new Point(Left + e.X - _dragOrigin.X, Top + e.Y - _dragOrigin.Y);
            }
            base.OnMouseMove(e);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            _dragging = false;
            base.OnMouseUp(e);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            // Shift+滚轮:调节透明度
            if ((ModifierKeys & Keys.Shift) == Keys.Shift)
            {
                Opacity = Math.Max(0.2, Math.Min(1.0, Opacity + (e.Delta > 0 ? 0.1 : -0.1)));
                return;
            }
            // 滚轮缩放:以光标为锚,光标下的图像点缩放后仍在光标处
            float scale = e.Delta > 0 ? 1.1f : 1f / 1.1f;
            Size next = ZoomSize(_image.Size, ClientSize, scale);
            int newW = next.Width, newH = next.Height;
            float fx = e.X / (float)Math.Max(1, ClientSize.Width);
            float fy = e.Y / (float)Math.Max(1, ClientSize.Height);
            var anchor = PointToScreen(e.Location);
            SuspendLayout();
            ClientSize = new Size(newW, newH);
            int nx = anchor.X - (int)(fx * newW);
            int ny = anchor.Y - (int)(fy * newH);
            // 钳位:窗口至少留 60px 在最近屏幕的工作区内
            var wa = Screen.FromPoint(anchor).WorkingArea;
            if (nx + newW < wa.X + 60) nx = wa.X + 60 - newW;
            if (ny + newH < wa.Y + 60) ny = wa.Y + 60 - newH;
            if (nx > wa.Right - 60) nx = wa.Right - 60;
            if (ny > wa.Bottom - 60) ny = wa.Bottom - 60;
            Location = new Point(nx, ny);
            ResumeLayout();
            Invalidate();
            base.OnMouseWheel(e);
        }

        internal static Size ZoomSize(Size original, Size current, float factor)
        {
            double ratio = original.Width / (double)original.Height;
            double maxWidth = Math.Min(8192, 8192 * ratio);
            double minWidth = Math.Min(40, Math.Max(1, 10 * ratio));
            int width = Math.Max(1, (int)Math.Round(Math.Max(minWidth, Math.Min(maxWidth, current.Width * factor))));
            int height = Math.Max(1, Math.Min(8192, (int)Math.Round(width / ratio)));
            return new Size(width, height);
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) Close();
            base.OnMouseDoubleClick(e);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) { Close(); e.Handled = true; }
            else if (e.Control && e.KeyCode == Keys.C)
            {
                if (Program.SetClipboardImageSafe(_image)) Program.ShowBalloon("贴图已复制");
                else Program.ShowBalloon("剪贴板被占用,复制失败");
                e.Handled = true;
            }
            else if (e.KeyCode == Keys.T) { _topMost = !_topMost; TopMost = _topMost; e.Handled = true; }
            base.OnKeyDown(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Right)
            {
                using (var m = new ContextMenu())
                {
                m.MenuItems.Add("复制", (s, a) =>
                {
                    if (Program.SetClipboardImageSafe(_image)) Program.ShowBalloon("贴图已复制");
                    else Program.ShowBalloon("剪贴板被占用,复制失败");
                });
                m.MenuItems.Add(_topMost ? "取消置顶" : "置顶", (s, a) => { _topMost = !_topMost; TopMost = _topMost; });
                m.MenuItems.Add("-");
                m.MenuItems.Add("关闭贴图", (s, a) => Close());
                m.Show(this, e.Location);
                }
            }
            base.OnMouseClick(e);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            RemoveRegisteredHandle();
            _registeredHandle = Handle;
            if (!Program.OpenPinHandles.Contains(_registeredHandle)) Program.OpenPinHandles.Add(_registeredHandle);
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            RemoveRegisteredHandle();
            base.OnHandleDestroyed(e);
        }

        private void RemoveRegisteredHandle()
        {
            if (_registeredHandle == IntPtr.Zero) return;
            Program.OpenPinHandles.Remove(_registeredHandle);
            _registeredHandle = IntPtr.Zero;
        }

        protected override void Dispose(bool disposing)
        {
            RemoveRegisteredHandle();
            if (disposing && !_resourcesDisposed)
            {
                _resourcesDisposed = true;
                Region current = Region;
                Region = null;
                if (current != null) current.Dispose();
                if (_imageRegion != null) _imageRegion.Dispose();
                _image.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
