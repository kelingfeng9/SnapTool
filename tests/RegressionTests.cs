using System;
using System.Collections;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SnapTool
{
    internal static class RegressionTests
    {
        private static int _passed;
        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        private static readonly string Output = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "test-results");
        [STAThread]
        private static int Main()
        {
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Directory.CreateDirectory(Output);
                TestHotkeys();
                TestConfiguration();
                TestCapture();
                AnnotationTests.Run(Check, Output);
                ShapeTests.Run(Check, Output);
                TestShapeInteraction();
                TestQuickSave();
                TestSettingsAndCountdown();
                SettingsTests.Run(Check, Output);
                TestSettingsEntry();
                TestPin();
                TestTransparentOutputs();
                TestOcr();
                Console.WriteLine("PASS: " + _passed + " assertions");
                return 0;
            }
            catch (Exception ex) { Console.WriteLine("FAIL: " + ex); return 1; }
        }
        private static void Check(bool ok, string message)
        {
            if (!ok) throw new Exception(message);
            _passed++; Console.WriteLine("PASS " + message);
        }
        private static object Get(object instance, string field) { return instance.GetType().GetField(field, Private).GetValue(instance); }
        private static void Set(object instance, string field, object value) { instance.GetType().GetField(field, Private).SetValue(instance, value); }
        private static object Call(object instance, string method, params object[] args)
        {
            return instance.GetType().GetMethod(method, Private).Invoke(instance, args);
        }
        private static void TestHotkeys()
        {
            KeyModifiers mods; Keys key;
            foreach (string input in new[] { "Ctrl+Alt+A", "Ctrl+1", "Shift+F11", "Ctrl+\\", "Control+Oemplus" })
                Check(Program.TryParseHotkey(input, out mods, out key), "parse " + input);
            foreach (string input in new[] { "Ctrl+Bogus+A", "Ctrl++A", "Ctrl+Alt", "Ctrl+999", "Ctrl+-1", "Ctrl+LButton", "Ctrl+F12", "Ctrl+A,B", "A", "Ctrl+" })
                Check(!Program.TryParseHotkey(input, out mods, out key), "reject " + input);
            Program.TryParseHotkey("Ctrl+1", out mods, out key);
            Check(key == Keys.D1, "digit uses virtual D1 key");
            using (var original = new HotKeyWindow())
            using (var blocker = new HotKeyWindow())
            using (var observer = new HotKeyWindow())
            {
                var m = KeyModifiers.Control | KeyModifiers.Alt | KeyModifiers.Shift;
                Check(original.Register(Keys.F9, m), "register original hotkey");
                Check(blocker.Register(Keys.F10, m), "reserve conflicting hotkey");
                Check(!original.Register(Keys.F10, m), "reject occupied hotkey");
                Check(!observer.Register(Keys.F9, m), "original hotkey remains registered after conflict");
                Check(original.Register(Keys.F9, m), "saving unchanged hotkey succeeds");
                original.Unregister();
                Check(observer.Register(Keys.F9, m), "unregister releases hotkey");
            }
        }
        private static void TestConfiguration()
        {
            string dir = Path.Combine(Output, "config-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            string portable = Path.Combine(dir, "portable.txt"), fallback = Path.Combine(dir, "appdata", "config.txt");
            File.WriteAllText(portable, "Ctrl+Shift+1\r\n");
            var store = new ConfigurationStore(portable, fallback);
            store.Set("ocr", "zh-Hans-CN");
            Check(store.Get("hotkey") == "Ctrl+Shift+1", "legacy hotkey survives unrelated config write");
            Check(store.Get("ocr") == "zh-Hans-CN", "config writes persist");
            File.WriteAllText(portable, "hotkey=Ctrl+A\nhotkey=Ctrl+B\npinwin=0\n");
            store.Set("ocr", "");
            Check(store.Get("hotkey") == "Ctrl+B", "duplicate config keys normalized");
            Check(store.Get("pinwin") == "0", "unknown-to-operation settings retained");
            Directory.CreateDirectory(Path.GetDirectoryName(fallback));
            File.WriteAllText(fallback, "hotkey=Ctrl+9\nocr=en-US\n");
            File.SetLastWriteTimeUtc(portable, DateTime.UtcNow.AddDays(-1));
            Check(new ConfigurationStore(portable, fallback).Get("hotkey") == "Ctrl+9", "new fallback overrides stale portable settings on restart");
            store.Set("pinwin", "1");
            Check(new ConfigurationStore(portable, fallback).Get("ocr") == "en-US", "fallback updates preserve latest values");
            string blocked = Path.Combine(dir, "blocked"); Directory.CreateDirectory(blocked);
            var unwritable = new ConfigurationStore(blocked, Path.Combine(dir, "recovery.txt"));
            unwritable.Set("hotkey", "Ctrl+2");
            Check(unwritable.Get("hotkey") == "Ctrl+2", "unwritable portable target falls back successfully");
            Check(Directory.GetFiles(dir, "*.tmp", SearchOption.AllDirectories).Length == 0, "atomic saves leave no temporary files");
        }
        private static CaptureForm NewCapture()
        {
            var bitmap = new Bitmap(800, 600);
            using (var g = Graphics.FromImage(bitmap)) g.Clear(Color.White);
            var form = new CaptureForm(bitmap) { Location = new Point(-20000, -20000), TopMost = false };
            form.Show();
            Application.DoEvents();
            return form;
        }
        private static MouseEventArgs Mouse(MouseButtons button, int x, int y) { return new MouseEventArgs(button, 1, x, y, 0); }
        private static void Select(CaptureForm form, Rectangle selection)
        {
            Set(form, "_sel", selection);
            Call(form, "EnterEditing");
        }
        private static void TestCapture()
        {
            using (var form = NewCapture())
            {
                Select(form, new Rectangle(20, 20, 740, 500));
                var toolbar = (FlowLayoutPanel)Get(form, "_toolbar");
                Check(toolbar.Right <= form.ClientSize.Width && toolbar.Bottom <= form.ClientSize.Height, "toolbar fits narrow screen");
                foreach (Control item in toolbar.Controls)
                    if (item.Text == "退出") Check(item.Bottom <= toolbar.ClientSize.Height, "wrapped toolbar keeps final action accessible");
                Call(form, "SelectTool", Tool.Text);
                Call(form, "ShowTextBox", new Point(700, 350));
                var box = (TextBox)Get(form, "_textBox");
                box.Text = "Test 123 [abc]";
                foreach (Keys input in new[] { Keys.D1, Keys.Back, Keys.Control | Keys.C, Keys.Control | Keys.Z, Keys.OemOpenBrackets })
                {
                    var key = new KeyEventArgs(input); Call(form, "OnKeyDown", key);
                    Check(!key.Handled && !key.SuppressKeyPress && !form.IsDisposed, "text editor owns " + input);
                }
                Call(form, "TextBoxKeyDown", box, new KeyEventArgs(Keys.Enter));
                var items = (IList)Get(form, "_items");
                Check(items.Count == 1, "Enter commits one text annotation");
                Check(((Annotation)items[0]).P1 == new Point(700, 350), "text uses click origin even when editor is clamped");
                Check(box.Font.Unit == GraphicsUnit.Pixel, "editor and rendered text use pixel units");
                Call(form, "ShowTextBox", new Point(100, 130)); box.Text = "Keep on blur";
                Call(form, "SelectTool", Tool.Rect);
                Check(items.Count == 2, "changing tool preserves text");
                Call(form, "ShowTextBox", new Point(100, 170)); box.Text = "Cancel";
                Call(form, "TextBoxKeyDown", box, new KeyEventArgs(Keys.Escape));
                Check(items.Count == 2 && !form.IsDisposed, "Escape cancels only text entry");
                Call(form, "ShowTextBox", new Point(100, 220)); box.Text = "Save pending text";
                using (var rendered = (Bitmap)Call(form, "RenderSelection"))
                {
                    Check(items.Count == 3 && rendered.Size == new Size(740, 500), "render commits pending text and preserves crop dimensions");
                    rendered.Save(Path.Combine(Output, "text-render.png"), ImageFormat.Png);
                }
                Call(form, "Reselect");
                Set(form, "_sel", new Rectangle(200, 200, 100, 100));
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 250, 250));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, -500, -500));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, -500, -500));
                Check((Rectangle)Get(form, "_sel") == new Rectangle(0, 0, 100, 100), "moving crop clamps without shrinking");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Right, 50, 50));
                Check(((Rectangle)Get(form, "_sel")).IsEmpty && !toolbar.Visible, "right-click resets selection and hides toolbar");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 50, 50));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, 1000, 800));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 1000, 800));
                Check((Rectangle)Get(form, "_sel") == new Rectangle(50, 50, 750, 550), "dragging outside screen clips crop");
                Select(form, new Rectangle(30, 30, 300, 200));
                Call(form, "SelectTool", Tool.Pen);
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 40, 40));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 200, 100));
                items = (IList)Get(form, "_items");
                var stroke = (Annotation)items[items.Count - 1];
                Check(stroke.Points[stroke.Points.Count - 1] == new Point(200, 100), "stroke includes final mouse-up position");
                Set(form, "_sel", new Rectangle(-50, -60, 150, 160));
                using (var rendered = (Bitmap)Call(form, "RenderSelection"))
                    Check(rendered.Size == new Size(100, 100), "render never allocates offscreen crop area");
            }
        }
        private static void TestShapeInteraction()
        {
            using (var form = NewCapture())
            {
                Check((CaptureShape)Get(form, "_shape") == CaptureShape.Rectangle, "new captures default to rectangle");
                var buttons = (System.Collections.Generic.List<Button>)Get(form, "_shapeButtons");
                Check(buttons[0].Text.Contains("矩形") && buttons[1].Text.Contains("圆形"), "shape controls prioritize rectangle then circle");
                var shapeBar = (FlowLayoutPanel)Get(form, "_shapeBar");
                bool settingsVisible = false;
                foreach (Control control in shapeBar.Controls)
                    if (control.Text == "快捷键设置") settingsVisible = true;
                Check(settingsVisible, "capture interface exposes the shortcut settings entry");
                Call(form, "SelectShape", CaptureShape.Circle);
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 50, 100));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, 350, 260));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 350, 260));
                Check((Rectangle)Get(form, "_sel") == new Rectangle(50, 100, 160, 160), "circle drag always produces a square crop");
                using (var rendered = (Bitmap)Call(form, "RenderSelection"))
                    Check(rendered.GetPixel(0, 0).A == 0 && rendered.GetPixel(80, 80).A == 255, "circle interaction exports actual transparent corners");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 210, 180));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, 270, 180));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 270, 180));
                Check((Rectangle)Get(form, "_sel") == new Rectangle(50, 70, 220, 220), "circle edge resize enlarges the circle and preserves opposite anchor");
                using (var preview = new Bitmap(form.Width, form.Height))
                {
                    form.DrawToBitmap(preview, new Rectangle(Point.Empty, form.Size));
                    preview.Save(Path.Combine(Output, "shape-ui-preview.png"));
                }
                Call(form, "SelectShape", CaptureShape.Triangle);
                using (var rendered = (Bitmap)Call(form, "RenderSelection"))
                    Check(rendered.GetPixel(0, 0).A == 0 && rendered.GetPixel(80, 130).A == 255, "selected region can switch to triangle");
                Call(form, "SelectShape", CaptureShape.Polygon);
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 50, 50));
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 250, 50));
                Call(form, "OnKeyDown", new KeyEventArgs(Keys.Enter));
                Check(!(bool)Get(form, "_polygonClosed") && ((Rectangle)Get(form, "_sel")).IsEmpty, "two polygon vertices cannot be finalized or exported");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 200, 150));
                Call(form, "OnMouseDown", Mouse(MouseButtons.Right, 200, 150));
                var points = (System.Collections.Generic.List<Point>)Get(form, "_polygonPoints");
                Check(points.Count == 2, "right-click withdraws the last polygon vertex");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 200, 150));
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 250, 250));
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 50, 250));
                var completeKey = new KeyEventArgs(Keys.Enter);
                Call(form, "OnKeyDown", completeKey);
                Check((bool)Get(form, "_polygonClosed") && !form.IsDisposed && completeKey.Handled, "Enter finalizes polygon without copying or closing");
                Check((Rectangle)Get(form, "_sel") == new Rectangle(50, 50, 200, 200), "polygon crop matches vertex bounds");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 100, 100));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, 150, 180));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 150, 180));
                Check((Rectangle)Get(form, "_sel") == new Rectangle(100, 130, 200, 200) && points[0] == new Point(100, 130), "moving polygon also moves every vertex");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 300, 330));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, 400, 430));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 400, 430));
                Check((Rectangle)Get(form, "_sel") == new Rectangle(100, 130, 300, 300) && points[1] == new Point(400, 130), "resizing polygon transforms its geometry with crop");
                Call(form, "OnMouseDown", Mouse(MouseButtons.Left, 400, 430));
                Call(form, "OnMouseMove", Mouse(MouseButtons.Left, 101, 131));
                Call(form, "OnMouseUp", Mouse(MouseButtons.Left, 101, 131));
                Check(points.Count == 0 && !(bool)Get(form, "_polygonClosed"), "shrinking polygon to zero returns to vertex selection");
                Call(form, "Reselect");
                Check(points.Count == 0 && !(bool)Get(form, "_polygonClosed"), "reselection clears polygon geometry");
                foreach (var p in new[] { new Point(100, 100), new Point(200, 100), new Point(200, 200) })
                    Call(form, "OnMouseDown", Mouse(MouseButtons.Left, p.X, p.Y));
                Call(form, "OnMouseDoubleClick", Mouse(MouseButtons.Left, 200, 200));
                Check((bool)Get(form, "_polygonClosed") && !form.IsDisposed, "double-click finishes polygon and leaves editing available");
                Call(form, "OnMouseDoubleClick", Mouse(MouseButtons.Left, 180, 120));
                Check(!form.IsDisposed, "polygon finishing double-click never immediately exports capture");
            }
            using (var defaultAgain = NewCapture())
                Check((CaptureShape)Get(defaultAgain, "_shape") == CaptureShape.Rectangle, "circle selection does not replace next capture rectangle default");
            using (var form = NewCapture())
            {
                Select(form, new Rectangle(50, 50, 400, 300));
                Call(form, "SelectTool", Tool.Text);
                Call(form, "ShowTextBox", new Point(100, 100));
                ((TextBox)Get(form, "_textBox")).Text = "Keep across shape changes";
                Call(form, "SelectShape", CaptureShape.Polygon);
                var items = (IList)Get(form, "_items");
                Check(items.Count == 1, "switching to polygon commits and preserves text annotation");
                foreach (var p in new[] { new Point(50, 50), new Point(450, 50), new Point(450, 350), new Point(50, 350) })
                    Call(form, "OnMouseDown", Mouse(MouseButtons.Left, p.X, p.Y));
                Call(form, "CompletePolygon");
                Check(items.Count == 1 && Get(form, "_mode").ToString() == "Editing", "polygon completion restores retained annotation preview");
                Call(form, "Reselect");
                Check(items.Count == 0, "explicit reselect still discards annotations");
            }
        }

        private static void TestSettingsEntry()
        {
            using (var capture = NewCapture())
            using (var timer = new System.Windows.Forms.Timer { Interval = 50 })
            {
                bool seen = false, owned = false, foreground = false;
                timer.Tick += (s, e) =>
                {
                    SettingsForm dialog = null;
                    foreach (Form form in Application.OpenForms) if (form is SettingsForm) dialog = (SettingsForm)form;
                    if (dialog == null) return;
                    timer.Stop();
                    seen = true; owned = dialog.Owner == capture;
                    foreground = dialog.TopMost && dialog.StartPosition == FormStartPosition.CenterParent;
                    dialog.Close();
                };
                timer.Start();
                try { Program.OpenSettings(capture); }
                finally { timer.Stop(); }
                Check(seen, "capture shortcut settings opens a real modal dialog");
                Check(owned, "shortcut settings is owned by the active capture");
                Check(foreground && !capture.IsDisposed, "shortcut settings stays above capture and cancellation preserves selection window");
            }
        }

        private static void TestTransparentOutputs()
        {
            using (var source = new Bitmap(80, 60, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(source)) g.Clear(Color.DodgerBlue);
                using (var circle = SelectionGeometry.Render(source, new Rectangle(0, 0, 80, 60), CaptureShape.Circle, null, null))
                {
                    byte[] dib = ImageClipboard.CreateDibV5(circle);
                    Check(BitConverter.ToUInt32(dib, 0) == 124 && dib.Length == 124 + 80 * 60 * 4, "clipboard DIBV5 includes a full header and pixel buffer");
                    Check(BitConverter.ToInt32(dib, 8) == -60 && BitConverter.ToUInt32(dib, 52) == 0xff000000, "clipboard DIBV5 declares top-down rows and alpha mask");
                    Check(dib[127] == 0 && dib[124 + (30 * 80 + 40) * 4 + 3] == 255, "clipboard DIBV5 preserves transparent corners and opaque center");
                    using (var normalized = ImageClipboard.CreateArgbBitmap(circle))
                        Check(normalized.GetPixel(0, 0).A == 0 && normalized.GetPixel(40, 30).ToArgb() == circle.GetPixel(40, 30).ToArgb(), "clipboard PNG source retains source transparency and colors");
                    using (var region = PinForm.CreateImageRegion(circle))
                        Check(!region.IsVisible(0, 0) && region.IsVisible(40, 30), "transparent pin region omits crop corners");
                    using (var pin = new PinForm((Bitmap)circle.Clone(), new Point(10, 10)))
                    {
                        Check(pin.Region != null && !pin.Region.IsVisible(0, 0) && pin.Region.IsVisible(40, 30), "pin starts with the screenshot silhouette");
                        pin.ClientSize = new Size(160, 120);
                        Check(!pin.Region.IsVisible(0, 0) && pin.Region.IsVisible(80, 60), "pin zoom scales its visible silhouette");
                        IntPtr handle = pin.Handle;
                        pin.Dispose();
                        Check(!Program.OpenPinHandles.Contains(handle), "transparent pin disposal releases registered handle");
                    }
                }
                using (var region = PinForm.CreateImageRegion(source))
                    Check(region == null, "opaque rectangle pins retain ordinary rectangular windows");
            }
        }

        private static void TestPin()
        {
            Check(PinForm.ZoomSize(new Size(1, 8000), new Size(1, 8000), 1.1f).Height <= 8192, "portrait pin height is bounded");
            Check(PinForm.ZoomSize(new Size(8000, 1), new Size(8000, 1), 1.1f).Width <= 8192, "landscape pin width is bounded");
            Size normal = PinForm.ZoomSize(new Size(800, 400), new Size(800, 400), 1.1f);
            Check(normal == new Size(880, 440), "pin zoom preserves aspect ratio");
            using (var form = new PinForm(new Bitmap(200, 100), new Point(10, 10)))
            {
                IntPtr handle = form.Handle;
                Check(Program.OpenPinHandles.Contains(handle), "pin handle registered");
                form.Dispose();
                Check(!Program.OpenPinHandles.Contains(handle), "pin handle removed on dispose");
            }
        }

        private static void TestQuickSave()
        {
            string directory = Path.Combine(Output, "quicksave-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            using (var bmp = new Bitmap(16, 16))
            {
                bmp.SetPixel(0, 0, Color.Red);
                string first = CaptureForm.SaveQuickImage(bmp, directory);
                bmp.SetPixel(0, 0, Color.Blue);
                string second = CaptureForm.SaveQuickImage(bmp, directory);
                Check(first != second && File.Exists(first) && File.Exists(second), "rapid quick saves create separate files");
                using (var one = new Bitmap(first))
                using (var two = new Bitmap(second))
                    Check(one.GetPixel(0, 0).ToArgb() == Color.Red.ToArgb() && two.GetPixel(0, 0).ToArgb() == Color.Blue.ToArgb(), "second quick save never overwrites first pixels");
            }
        }

        private static void TestSettingsAndCountdown()
        {
            using (var settings = new SettingsForm("Ctrl+1"))
            {
                Check(settings.ResultMods == KeyModifiers.Control && settings.ResultKey == Keys.D1, "settings retain unchanged initial hotkey");
                Call(settings, "BeginRecording");
                var args = new object[] { new Message(), Keys.Control | Keys.Tab };
                Check((bool)Call(settings, "ProcessCmdKey", args) && settings.ResultKey == Keys.Tab, "settings capture dialog keys with modifiers");
                Call(settings, "BeginRecording");
                var invalid = new KeyEventArgs(Keys.Control | Keys.F12);
                Call(settings, "OnKeyDown", invalid);
                Check(settings.ResultKey == Keys.Tab, "reserved key does not overwrite valid choice");
            }
            using (var countdown = new CountdownForm(3))
            {
                countdown.Location = new Point(-20000, -20000);
                countdown.Show();
                countdown.ForceCancel();
                Check(countdown.IsDisposed, "cancelled countdown disposes its form and timers");
            }
        }
        private static Bitmap OcrSample(int width)
        {
            var bmp = new Bitmap(width, 220);
            using (var g = Graphics.FromImage(bmp))
            using (var font = new Font("Arial", 32, FontStyle.Regular, GraphicsUnit.Pixel))
            {
                g.Clear(Color.White);
                g.DrawString("HELLO SNAPTOOL 123", font, Brushes.Black, 25, 25);
                g.DrawString("SECOND LINE 456", font, Brushes.Black, 25, 100);
            }
            return bmp;
        }
        private static void TestOcr()
        {
            Console.WriteLine("OCR engine: " + OcrHelper.EngineName());
            Check(OcrHelper.IsAvailable(), "installed OCR engine available");
            var task = Task.Run(() =>
            {
                using (var bmp = OcrSample(800)) return OcrHelper.Recognize(bmp, null);
            });
            Check(task.Wait(30000), "OCR completes within 30 seconds");
            Console.WriteLine("OCR result: " + task.Result.Replace(Environment.NewLine, " / "));
            Check(task.Result.Contains("123") && task.Result.Contains("456") && task.Result.Contains(Environment.NewLine), "real OCR recognizes both lines and retains newline");
            var large = Task.Run(() => { using (var bmp = OcrSample(5000)) return OcrHelper.Recognize(bmp, null); });
            Check(large.Wait(30000) && large.Result.Contains("123"), "oversize OCR image is downscaled successfully");
            using (var result = new OcrResultForm(task.Result))
            {
                result.Location = new Point(-20000, -20000); result.StartPosition = FormStartPosition.Manual;
                result.Show(); Application.DoEvents();
                var tb = (TextBox)Get(result, "_tb");
                foreach (Control c in result.Controls)
                    if (c is Panel) Check(tb.Bottom <= c.Top, "OCR text area does not cover bottom buttons");
                using (var preview = new Bitmap(result.Width, result.Height))
                { result.DrawToBitmap(preview, new Rectangle(Point.Empty, result.Size)); preview.Save(Path.Combine(Output, "ocr-layout.png")); }
            }
            using (var form = NewCapture())
            {
                Program.StartOcr(OcrSample(800));
                form.Close();
                var watch = System.Diagnostics.Stopwatch.StartNew();
                while (Program.OcrBusy && watch.ElapsedMilliseconds < 30000) { Application.DoEvents(); Thread.Sleep(15); }
                Application.DoEvents();
                Form found = null;
                foreach (Form open in Application.OpenForms) if (open is OcrResultForm) found = open;
                Check(found != null, "OCR result survives closing capture before completion");
                if (found != null) found.Close();
            }
        }
    }
}
