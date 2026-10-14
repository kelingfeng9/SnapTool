using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace SnapTool
{
    // 本地 OCR:调用系统自带的 Windows.Media.Ocr 引擎(简体中文 zh-Hans-CN 已随系统安装)。
    // 运行时零额外依赖(系统 WinRT + GAC facade)。
    // 不引用 System.Runtime.WindowsRuntime.dll(无 SDK 机器上其顶层 Windows winmd 依赖缺失),
    // 改用手写 WaitFor 处理 IAsyncOperation。
    internal static class OcrHelper
    {
        private static string _langTag;
        public static string CurrentLanguageTag { get { return _langTag; } }
        public static void SetLanguage(string tag) { _langTag = string.IsNullOrWhiteSpace(tag) ? null : tag; }

        public static Windows.Globalization.Language[] AvailableLanguageTags()
        {
            var list = new System.Collections.Generic.List<Windows.Globalization.Language>();
            try { foreach (var lg in OcrEngine.AvailableRecognizerLanguages) list.Add(lg); }
            catch { }
            return list.ToArray();
        }

        private static OcrEngine Engine(string tag)
        {
            if (tag != null)
                return OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language(tag));
            var engine = OcrEngine.TryCreateFromUserProfileLanguages();
            if (engine != null) return engine;
            foreach (var lg in OcrEngine.AvailableRecognizerLanguages)
                return OcrEngine.TryCreateFromLanguage(lg);
            return null;
        }

        public static bool IsAvailable()
        {
            try { return Engine(_langTag) != null; }
            catch { return false; }
        }

        public static string EngineName()
        {
            try { var engine = Engine(_langTag); return engine == null ? null : engine.RecognizerLanguage.LanguageTag; }
            catch { return null; }
        }
        // 识别一块位图,返回整理后的文本(中文逐字空格已合并)。必须在后台线程调用。
        public static string Recognize(Bitmap bmp, string languageTag)
        {
            var e = Engine(languageTag);
            if (bmp == null) throw new ArgumentNullException("bmp");
            if (e == null) throw new InvalidOperationException("未找到所选语言的 OCR 引擎，请检查系统识别语言包。");
            SoftwareBitmap sb = null;
            Bitmap scaled = null;
            try
            {
                // 系统 OCR 引擎有最大边长限制(通常 4096px);跨屏/整屏大框选先等比缩小,否则识别必然失败
                uint maxDim = OcrEngine.MaxImageDimension;
                Bitmap src = bmp;
                if (bmp.Width > maxDim || bmp.Height > maxDim)
                {
                    float s = Math.Min((float)maxDim / bmp.Width, (float)maxDim / bmp.Height);
                    int w = Math.Max(1, (int)(bmp.Width * s)), h = Math.Max(1, (int)(bmp.Height * s));
                    scaled = new Bitmap(w, h, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(scaled))
                    {
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                        g.DrawImage(bmp, 0, 0, w, h);
                    }
                    src = scaled;
                }
                sb = ToSoftwareBitmap(src);
                if (sb == null) return null;
                OcrResult r = WaitFor(e.RecognizeAsync(sb));
                var lines = new StringBuilder();
                foreach (var line in r.Lines)
                {
                    if (lines.Length > 0) lines.AppendLine();
                    lines.Append(CleanText(line.Text));
                }
                return lines.ToString();
            }
            finally { CloseWinRt(sb); if (scaled != null) scaled.Dispose(); }

        }

        // Windows OCR 对中文常输出"你 好 世 界"(逐字成词),合并相邻 CJK 字符间的空格。
        private static string CleanText(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            var sb = new StringBuilder();
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == ' ' && sb.Length > 0 && i + 1 < s.Length
                    && IsCjk(sb[sb.Length - 1]) && IsCjk(s[i + 1]))
                {
                    continue;
                }
                sb.Append(c);
            }
            return sb.ToString().Trim();
        }

        private static bool IsCjk(char c) { return c >= 0x4E00 && c <= 0x9FFF; }

        private static SoftwareBitmap ToSoftwareBitmap(Bitmap bmp)
        {
            using (var ms = new MemoryStream())
            {
                bmp.Save(ms, ImageFormat.Png);
                var ras = new InMemoryRandomAccessStream();
                DataWriter dw = null;
                try
                {
                    dw = new DataWriter(ras);
                    dw.WriteBytes(ms.ToArray());
                    WaitFor(dw.StoreAsync());
                    dw.DetachStream();
                    ras.Seek(0);
                    var decoder = WaitFor(BitmapDecoder.CreateAsync(ras));
                    return WaitFor(decoder.GetSoftwareBitmapAsync());
                }
                finally { CloseWinRt(dw); CloseWinRt(ras); }
            }
        }

        private static void CloseWinRt(object resource)
        {
            // The CLR projects WinRT IClosable as IDisposable at runtime.
            var disposable = resource as IDisposable;
            if (disposable != null) disposable.Dispose();
        }

        private static T WaitFor<T>(IAsyncOperation<T> op)
        {
            var completed = new System.Threading.Tasks.TaskCompletionSource<T>();
            op.Completed = delegate(IAsyncOperation<T> operation, AsyncStatus status)
            {
                try
                {
                    if (status == AsyncStatus.Completed) completed.TrySetResult(operation.GetResults());
                    else if (status == AsyncStatus.Canceled) completed.TrySetCanceled();
                    else completed.TrySetException(operation.ErrorCode ?? new InvalidOperationException("OCR 操作失败"));
                }
                catch (Exception ex) { completed.TrySetException(ex); }
                finally { operation.Close(); }
            };
            return completed.Task.GetAwaiter().GetResult();
        }
    }
    // OCR 结果浮窗:可编辑、可复制全部。
    internal sealed class OcrResultForm : Form
    {
        private readonly TextBox _tb;

        public OcrResultForm(string text)
        {
            Text = "OCR 识别结果";
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            ShowInTaskbar = true;
            KeyPreview = true;
            ClientSize = new Size(460, 300);
            MinimumSize = new Size(280, 180);
            FormBorderStyle = FormBorderStyle.SizableToolWindow;
            MinimizeBox = false;
            MaximizeBox = false;
            Font = new Font("Microsoft YaHei UI", 9);

            var bar = new Panel { Dock = DockStyle.Bottom, Height = 38, BackColor = Color.FromArgb(245, 245, 248) };
            var btnCopy = new Button { Text = "复制全部", Size = new Size(90, 28), Left = 10, Top = 5 };
            var btnClose = new Button { Text = "关闭", Size = new Size(70, 28), Left = 108, Top = 5, DialogResult = DialogResult.Cancel };
            btnCopy.Click += delegate(object s, EventArgs e)
            {
                if (string.IsNullOrEmpty(_tb.Text)) return;
                if (Program.SetClipboardTextSafe(_tb.Text)) Program.ShowBalloon("已复制识别文字");
                else MessageBox.Show("剪贴板被占用,复制失败");
            };
            bar.Controls.Add(btnCopy);
            bar.Controls.Add(btnClose);

            _tb = new TextBox
            {
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill,
                Text = text ?? "",
                Font = new Font("Microsoft YaHei UI", 11),
                WordWrap = true,
                AcceptsTab = true,
            };

            // bar 先加入(top z-order)先占据底部,文本框 Fill 占据剩余
            Controls.Add(_tb);
            Controls.Add(bar);

            CancelButton = btnClose;
            Shown += delegate(object s, EventArgs e) { _tb.SelectAll(); _tb.Focus(); };
        }
    }
}
