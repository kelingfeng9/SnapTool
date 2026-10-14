using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace SnapTool
{
    internal static class Program
    {
        private static NotifyIcon _tray;
        private static HotKeyWindow _hotkey;
        private static MenuItem _captureMenuItem;
        private static string _currentHotkey;
        private static CountdownForm _countdown;
        private static MenuItem _autoStartItem;
        private static MenuItem _pinWinItem;
        private static MenuItem _ocrMenu;
        private static Control _dispatcher;
        private static bool _ocrBusy;
        private static bool _quitting;
        private static bool _settingsOpen;

        // 贴图窗口句柄注册表:窗口识别时可据此包含/排除贴图
        internal static readonly List<IntPtr> OpenPinHandles = new List<IntPtr>();
        // 是否把贴图当作普通窗口参与"悬停选窗口"
        internal static bool IdentifyPinWindows = true;

        internal const string DefaultHotkey = "Ctrl+Alt+A";

        [STAThread]
        private static void Main(string[] args)
        {
            EnableDpiAwareness();
            bool createdNew;
            using (var mutex = new System.Threading.Mutex(true, "Local\\SnapTool_SingleInstance", out createdNew))
            {
            if (!createdNew) { HotKeyWindow.RequestCapture(); return; }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            EnsureDispatcher();

            _tray = new NotifyIcon
            {
                Icon = LoadAppIcon(),
                Visible = true,
                Text = "SnapTool 截图"
            };

            // 读取配置(旧版单行热键格式也兼容)
            IdentifyPinWindows = !string.Equals(GetConfigValue("pinwin"), "0", StringComparison.OrdinalIgnoreCase);
            string ocrTag = GetConfigValue("ocr");
            if (!string.IsNullOrEmpty(ocrTag)) OcrHelper.SetLanguage(ocrTag);

            var menu = new ContextMenu();
            _captureMenuItem = menu.MenuItems.Add("截图", (s, e) => StartCapture());

            var delay = new MenuItem("延迟截图");
            delay.MenuItems.Add("3 秒", (s, e) => StartCaptureDelayed(3));
            delay.MenuItems.Add("5 秒", (s, e) => StartCaptureDelayed(5));
            delay.MenuItems.Add("10 秒", (s, e) => StartCaptureDelayed(10));
            menu.MenuItems.Add(delay);

            menu.MenuItems.Add("-");
            menu.MenuItems.Add("设置快捷键...", (s, e) => OpenSettings());

            _autoStartItem = new MenuItem("开机自启");
            _autoStartItem.Checked = AutoStartEnabled();
            _autoStartItem.Click += (s, e) =>
            {
                if (!SetAutoStart(!_autoStartItem.Checked)) return;
                _autoStartItem.Checked = AutoStartEnabled();
                ShowBalloon(_autoStartItem.Checked ? "已开启开机自启" : "已关闭开机自启");
            };
            menu.MenuItems.Add(_autoStartItem);

            _pinWinItem = new MenuItem("截图时识别贴图窗口");
            _pinWinItem.Checked = IdentifyPinWindows;
            _pinWinItem.Click += (s, e) =>
            {
                IdentifyPinWindows = !_pinWinItem.Checked;
                _pinWinItem.Checked = IdentifyPinWindows;
                SetConfigValue("pinwin", IdentifyPinWindows ? "1" : "0");
            };
            menu.MenuItems.Add(_pinWinItem);

            _ocrMenu = new MenuItem("OCR 语言");
            _ocrMenu.Popup += (s, e) => BuildOcrMenu();
            menu.MenuItems.Add(_ocrMenu);

            menu.MenuItems.Add("-");
            menu.MenuItems.Add("关于 SnapTool", (s, e) =>
                MessageBox.Show(
                    "SnapTool v" + VersionText + " — 小巧截图工具\r\n\r\n" +
                    "截图快捷键可在「设置快捷键」中自由修改(Ctrl/Alt/Shift + 任意键)。\r\n\r\n" +
                    "截图时:拖动框选 / 悬停单击选窗口 / 双击复制\r\n" +
                    "Enter 复制 / Esc 取消 / 右键重来\r\n\r\n" +
                    "标注:矩形·箭头·画笔·文字·马赛克·序号·高亮(选中工具后 [ ] 或滚轮调参数)\r\n" +
                    "输出:复制 / 保存 / 快存(Ctrl+Shift+S) / 贴图",
                    "关于 SnapTool", MessageBoxButtons.OK, MessageBoxIcon.Information));
            menu.MenuItems.Add("退出", (s, e) => Quit());
            _tray.ContextMenu = menu;
            _tray.DoubleClick += (s, e) => StartCapture();

            _hotkey = new HotKeyWindow();
            _hotkey.HotKeyPressed += (s, e) => { if (!_settingsOpen) StartCapture(); };

            // 读取自定义快捷键并注册
            KeyModifiers m; Keys k;
            if (!TryParseHotkey(GetConfigValue("hotkey"), out m, out k))
            {
                TryParseHotkey(DefaultHotkey, out m, out k);
            }
            ApplyHotkey(m, k);

            Application.ApplicationExit += (s, e) =>
            {
                if (_hotkey != null) _hotkey.Unregister();
                if (_tray != null) _tray.Visible = false;
            };

            if (Array.IndexOf(args, "--capture") >= 0) StartCapture();
            try { Application.Run(); }
            finally
            {
                _quitting = true;
                if (_countdown != null) _countdown.ForceCancel();
                _hotkey.Dispose();
                _dispatcher.Dispose();
                _tray.Visible = false;
                _tray.Icon.Dispose();
                _tray.Dispose();
                menu.Dispose();
                mutex.ReleaseMutex();
            }
            }
        }

        // ---------- DPI 感知(高 DPI 屏坐标/截图准确)----------
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAware();

        private static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }   // PerMonitor V2(Win10 1703+)
            try { SetProcessDpiAware(); } catch { }                                          // 回退:System DPI 感知
        }

        // ---------- 图标 ----------
        private static Icon LoadAppIcon()
        {
            try { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { return (Icon)SystemIcons.Application.Clone(); }
        }

        // ---------- 配置(key=value 文本;exe 目录不可写时回退 %APPDATA%;兼容旧版单行热键)----------
        private const string ConfigFileName = "SnapTool.config.txt";

        private static string ExeConfigPath
        {
            get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ConfigFileName); }
        }

        private static string AppDataConfigPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SnapTool", ConfigFileName);
            }
        }

        private static readonly ConfigurationStore Config = new ConfigurationStore(ExeConfigPath, AppDataConfigPath);

        internal static string GetConfigValue(string key) { return Config.Get(key); }

        internal static bool SetConfigValue(string key, string value)
        {
            try { Config.Set(key, value); return true; }
            catch (Exception ex) { ShowBalloon("保存配置失败: " + ex.Message); return false; }
        }
        internal static bool TryParseHotkey(string s, out KeyModifiers mods, out Keys key)
        {
            mods = KeyModifiers.None;
            key = Keys.None;
            if (string.IsNullOrWhiteSpace(s)) return false;
            var parts = s.Split('+');
            for (int i = 0; i < parts.Length; i++)
            {
                var p = parts[i].Trim();
                if (i == parts.Length - 1)
                {
                    if (!TryParseKeyName(p, out key)) return false;
                }
                else
                {
                    KeyModifiers modifier;
                    switch (p.ToLowerInvariant())
                    {
                        case "ctrl":
                        case "control": modifier = KeyModifiers.Control; break;
                        case "alt": modifier = KeyModifiers.Alt; break;
                        case "shift": modifier = KeyModifiers.Shift; break;
                        case "win":
                        case "windows": modifier = KeyModifiers.WindowsKey; break;
                        default: return false;
                    }
                    if ((mods & modifier) != 0) return false;
                    mods |= modifier;
                }
            }
            if (mods == KeyModifiers.None || !IsValidHotkeyKey(key)) return false;
            return true;
        }

        internal static bool IsValidHotkeyKey(Keys key)
        {
            int code = (int)key;
            return code > 6 && code <= 254 && Enum.IsDefined(typeof(Keys), key) &&
                key != Keys.ShiftKey && key != Keys.ControlKey && key != Keys.Menu &&
                key != Keys.LShiftKey && key != Keys.RShiftKey && key != Keys.LControlKey &&
                key != Keys.RControlKey && key != Keys.LMenu && key != Keys.RMenu &&
                key != Keys.LWin && key != Keys.RWin && key != Keys.F12;
        }

        // 键名解析:兼容手写数字 0-9 与 ` - = [ ] ; ' , . / \ 等显示名
        internal static bool TryParseKeyName(string p, out Keys key)
        {
            key = Keys.None;
            if (string.IsNullOrWhiteSpace(p)) return false;
            switch (p.ToLowerInvariant())
            {
                case "esc": key = Keys.Escape; return true;
                case "pgup": key = Keys.PageUp; return true;
                case "pgdn": key = Keys.PageDown; return true;
                case "del": key = Keys.Delete; return true;
                case "空格": key = Keys.Space; return true;
            }
            if (p.Length == 1)
            {
                char c = p[0];
                if (c >= '0' && c <= '9') { key = (Keys)(48 + (c - '0')); return true; }   // "1" -> Keys.D1
                switch (c)
                {
                    case '`': key = Keys.Oem3; return true;
                    case '-': key = Keys.OemMinus; return true;
                    case '=': key = Keys.Oemplus; return true;
                    case '[': key = Keys.OemOpenBrackets; return true;
                    case ']': key = Keys.OemCloseBrackets; return true;
                    case ';': key = Keys.OemSemicolon; return true;
                    case '\'': key = Keys.OemQuotes; return true;
                    case ',': key = Keys.Oemcomma; return true;
                    case '.': key = Keys.OemPeriod; return true;
                    case '/': key = Keys.OemQuestion; return true;
                    case '\\': key = Keys.OemBackslash; return true;
                }
            }
            int numeric;
            if (int.TryParse(p, out numeric) || p.IndexOf(',') >= 0) return false;
            return Enum.TryParse(p, true, out key);
        }

        internal static string HotkeyToString(KeyModifiers mods, Keys key)
        {
            var sb = new StringBuilder();
            if ((mods & KeyModifiers.Control) != 0) sb.Append("Ctrl+");
            if ((mods & KeyModifiers.Alt) != 0) sb.Append("Alt+");
            if ((mods & KeyModifiers.Shift) != 0) sb.Append("Shift+");
            if ((mods & KeyModifiers.WindowsKey) != 0) sb.Append("Win+");
            sb.Append(key.ToString());
            return sb.ToString();
        }

        internal static string HotkeyToDisplay(KeyModifiers mods, Keys key)
        {
            var sb = new StringBuilder();
            if ((mods & KeyModifiers.Control) != 0) sb.Append("Ctrl + ");
            if ((mods & KeyModifiers.Alt) != 0) sb.Append("Alt + ");
            if ((mods & KeyModifiers.Shift) != 0) sb.Append("Shift + ");
            if ((mods & KeyModifiers.WindowsKey) != 0) sb.Append("Win + ");
            sb.Append(KeyFriendly(key));
            return sb.ToString();
        }

        internal static string KeyFriendly(Keys k)
        {
            string s = k.ToString();
            if (s.Length == 2 && s[0] == 'D' && char.IsDigit(s[1])) return s.Substring(1); // D1->1
            if (s.StartsWith("NumPad")) return "小键盘" + s.Substring(6);
            if (s == "Oem3" || s == "OemTilde") return "`";
            if (s == "OemMinus") return "-";
            if (s == "Oemplus") return "=";
            if (s == "OemOpenBrackets") return "[";
            if (s == "OemCloseBrackets") return "]";
            if (s == "OemSemicolon") return ";";
            if (s == "OemQuotes") return "'";
            if (s == "Oemcomma") return ",";
            if (s == "OemPeriod") return ".";
            if (s == "OemQuestion") return "/";
            if (s == "OemBackslash") return "\\";
            if (s == "Space") return "空格";
            return s;
        }

        private static bool ApplyHotkey(KeyModifiers mods, Keys key, bool notifyFailure = true)
        {
            if (_hotkey != null && _hotkey.Register(key, mods))
            {
                _currentHotkey = HotkeyToString(mods, key);
                string disp = HotkeyToDisplay(mods, key);
                if (_tray != null) _tray.Text = "SnapTool 截图 (" + disp + ")";
                if (_captureMenuItem != null) _captureMenuItem.Text = "截图   " + disp;
                return true;
            }
            else
            {
                if (string.IsNullOrEmpty(_currentHotkey))
                {
                    if (_tray != null) _tray.Text = "SnapTool 截图 (热键未注册)";
                    if (_captureMenuItem != null) _captureMenuItem.Text = "截图";
                }
                if (notifyFailure) ShowBalloon("注册热键 " + HotkeyToDisplay(mods, key) + " 失败，请换一个组合。" +
                    (string.IsNullOrEmpty(_currentHotkey) ? "" : "原快捷键仍然有效。"));
                return false;
            }
        }

        public static void OpenSettings()
        {
            OpenSettings(null);
        }

        public static void OpenSettings(Form owner)
        {
            if (_settingsOpen) return;
            _settingsOpen = true;
            try
            {
                using (var f = new SettingsForm(_currentHotkey, SaveHotkeySettings))
                {
                    bool hasOwner = owner != null && !owner.IsDisposed;
                    f.TopMost = true;
                    f.StartPosition = hasOwner ? FormStartPosition.CenterParent : FormStartPosition.CenterScreen;
                    DialogResult result = hasOwner ? f.ShowDialog(owner) : f.ShowDialog();
                    if (result == DialogResult.OK)
                        ShowBalloon("截图快捷键已设置为 " + HotkeyToDisplay(f.ResultMods, f.ResultKey));
                }
            }
            finally { _settingsOpen = false; }
        }

        private static HotkeySaveResult SaveHotkeySettings(KeyModifiers mods, Keys key)
        {
            if (!ApplyHotkey(mods, key, false))
                return new HotkeySaveResult(false, false,
                    "无法注册 " + HotkeyToDisplay(mods, key) + "，可能已被其他程序占用。请修改后重试。" +
                    (string.IsNullOrEmpty(_currentHotkey) ? "当前仍未注册快捷键。" : "原快捷键仍然有效。"));
            try
            {
                Config.Set("hotkey", HotkeyToString(mods, key));
                return new HotkeySaveResult(true, true, null);
            }
            catch (Exception)
            {
                return new HotkeySaveResult(true, false,
                    "配置保存失败，新快捷键仅临时生效。关闭窗口后仍可使用；重启软件后会恢复已保存的配置。请重试保存或改回原快捷键。");
            }
        }

        // ---------- 操作 ----------
        public static void StartCapture()
        {
            if (_countdown != null) _countdown.ForceCancel();
            foreach (Form f in Application.OpenForms)
                if (f is CaptureForm) { f.Activate(); return; }
            try { new CaptureForm().Show(); }
            catch (Exception ex) { MessageBox.Show("截图启动失败:\r\n" + ex.Message, "SnapTool"); }
        }

        public static void StartCaptureDelayed(int seconds)
        {
            // 单例:重复点击延迟截图时,先取消上一个倒计时
            if (_countdown != null) _countdown.ForceCancel();
            var f = new CountdownForm(seconds);
            _countdown = f;
            f.FormClosed += delegate { if (ReferenceEquals(_countdown, f)) _countdown = null; };
            f.Show();
        }

        public static void ShowBalloon(string text)
        {
            if (_tray != null)
            {
                _tray.BalloonTipTitle = "SnapTool";
                _tray.BalloonTipText = text;
                _tray.ShowBalloonTip(1500);
            }
        }

        internal static bool OcrBusy { get { return _ocrBusy; } }

        // Completion belongs to the application, not the disposable capture window.
        private static void EnsureDispatcher()
        {
            if (_dispatcher == null || _dispatcher.IsDisposed)
            {
                _dispatcher = new Control();
                IntPtr handle = _dispatcher.Handle;
            }
        }

        internal static void StartOcr(Bitmap region)
        {
            if (_ocrBusy || _quitting) { region.Dispose(); return; }
            EnsureDispatcher();
            _ocrBusy = true;
            string tag = OcrHelper.CurrentLanguageTag;
            ShowBalloon("正在识别文字…");
            System.Threading.Tasks.Task.Run(() =>
            {
                string result = null, error = null;
                try { using (region) result = OcrHelper.Recognize(region, tag); }
                catch (Exception ex) { error = ex.Message; }
                try
                {
                    _dispatcher.BeginInvoke((Action)delegate
                    {
                        _ocrBusy = false;
                        if (_quitting) return;
                        if (error != null) ShowBalloon("文字识别失败: " + error);
                        else if (string.IsNullOrWhiteSpace(result)) ShowBalloon("未识别到文字");
                        else new OcrResultForm(result).Show();
                    });
                }
                catch (InvalidOperationException) { /* Application dispatcher has already shut down. */ }
            });
        }

        public static void Quit()
        {
            _quitting = true;
            if (_countdown != null) _countdown.ForceCancel();
            if (_hotkey != null) _hotkey.Unregister();
            if (_tray != null) _tray.Visible = false;
            Application.Exit();
        }

        internal static string VersionText
        {
            get
            {
                try { return typeof(Program).Assembly.GetName().Version.ToString(3); }
                catch { return "1.1"; }
            }
        }

        // ---------- 剪贴板(带重试:剪贴板管理器/远程桌面短暂占用时不抛异常)----------
        public static bool SetClipboardImageSafe(Image img)
        {
            try
            {
                EnsureDispatcher();
                return ImageClipboard.SetImageSafe(img, _dispatcher.Handle);
            }
            catch { return false; }
        }

        public static bool SetClipboardTextSafe(string text)
        {
            if (string.IsNullOrEmpty(text)) return false;
            for (int i = 0; i < 5; i++)
            {
                try { Clipboard.SetText(text); return true; }
                catch { System.Threading.Thread.Sleep(30); }
            }
            return false;
        }

        // ---------- 开机自启(HKCU\...\Run)----------
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        private static bool AutoStartEnabled()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
                    return (k != null && k.GetValue("SnapTool") != null) || File.Exists(StartupShortcut);
            }
            catch { return false; }
        }

        private static string StartupShortcut
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "SnapTool.lnk"); }
        }

        private static bool SetAutoStart(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (k == null) throw new IOException("无法打开启动项注册表");
                    if (on) k.SetValue("SnapTool", "\"" + Application.ExecutablePath + "\"");
                    else k.DeleteValue("SnapTool", false);
                }
                if (!on && File.Exists(StartupShortcut))
                    File.Move(StartupShortcut, StartupShortcut + ".disabled-" + DateTime.Now.ToString("yyyyMMddHHmmssfff"));
                return true;
            }
            catch (Exception ex) { ShowBalloon("设置开机自启失败:" + ex.Message); return false; }
        }

        // ---------- OCR 语言菜单 ----------
        private static void BuildOcrMenu()
        {
            _ocrMenu.MenuItems.Clear();
            string cur = OcrHelper.CurrentLanguageTag;   // null=自动
            var auto = new MenuItem("自动(跟随系统语言)") { Checked = cur == null };
            auto.Click += (s, e) => SetOcrLanguage(null);
            _ocrMenu.MenuItems.Add(auto);
            _ocrMenu.MenuItems.Add("-");
            foreach (var lang in OcrHelper.AvailableLanguageTags())
            {
                string tag = lang.LanguageTag;
                var item = new MenuItem(tag) { Checked = string.Equals(tag, cur, StringComparison.OrdinalIgnoreCase) };
                item.Click += (s, e) => SetOcrLanguage(tag);
                _ocrMenu.MenuItems.Add(item);
            }
        }

        private static void SetOcrLanguage(string tag)
        {
            OcrHelper.SetLanguage(tag);
            SetConfigValue("ocr", tag ?? "");
            ShowBalloon("OCR 语言已切换为 " + (tag ?? "自动(跟随系统语言)") +
                        (OcrHelper.IsAvailable() ? "" : "(当前不可用)"));
        }
    }

    internal sealed class HotkeySaveResult
    {
        internal readonly bool Applied, Saved;
        internal readonly string Message;
        internal HotkeySaveResult(bool applied, bool saved, string message)
        {
            Applied = applied;
            Saved = saved;
            Message = message;
        }
    }

    /// <summary>快捷键设置:直接输入或主动录制，保存失败时可继续编辑。</summary>
    internal sealed class SettingsForm : Form
    {
        public KeyModifiers ResultMods = KeyModifiers.None;
        public Keys ResultKey = Keys.None;

        private readonly Label _cur;
        private readonly Label _status;
        private readonly TextBox _input;
        private readonly Button _record;
        private readonly Button _cancel;
        private readonly Font _headingFont;
        private readonly Font _normalFont;
        private readonly Func<KeyModifiers, Keys, HotkeySaveResult> _saveHotkey;
        private bool _recording;

        // Selection-only constructor for the existing regression harness.
        // The application always supplies SaveHotkeySettings to apply and persist.
        public SettingsForm(string initial) : this(initial, null) { }

        internal SettingsForm(string initial, Func<KeyModifiers, Keys, HotkeySaveResult> saveHotkey)
        {
            _saveHotkey = saveHotkey;
            AutoScaleMode = AutoScaleMode.Font;
            Text = "设置截图快捷键";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MaximizeBox = false;
            MinimizeBox = false;
            KeyPreview = true;
            _normalFont = new Font("Microsoft YaHei UI", 9);
            _headingFont = new Font("Microsoft YaHei UI", 12, FontStyle.Bold);
            Font = _normalFont;
            AutoScaleDimensions = CurrentAutoScaleDimensions;
            ClientSize = new Size(500, 310);

            var tip = new Label
            {
                Text = "可直接输入，例如 Ctrl+Alt+A（Win 组合也可手输）；\r\n或点击「录制快捷键」，按 Ctrl / Alt / Shift + 一个按键。",
                Location = new Point(20, 56),
                Size = new Size(460, 40)
            };

            KeyModifiers im; Keys ik;
            bool valid = Program.TryParseHotkey(initial, out im, out ik);
            _cur = new Label
            {
                Name = "CurrentHotkey",
                Text = valid ? "当前生效：" + Program.HotkeyToDisplay(im, ik) : "当前未注册快捷键",
                Location = new Point(20, 18),
                Size = new Size(460, 32),
                Font = _headingFont,
                ForeColor = Color.FromArgb(86, 134, 245)
            };

            var inputLabel = new Label { Text = "新快捷键", Location = new Point(20, 101), Size = new Size(300, 22) };
            _input = new TextBox
            {
                Name = "HotkeyInput", Location = new Point(20, 126), Size = new Size(322, 30),
                Text = valid ? Program.HotkeyToString(im, ik) : Program.DefaultHotkey,
                TabIndex = 0
            };
            _record = new Button
            {
                Name = "RecordHotkey", Text = "录制快捷键", Location = new Point(356, 124),
                Size = new Size(124, 32), TabIndex = 1
            };
            _status = new Label
            {
                Name = "HotkeyStatus", Text = "修改后点击保存。快捷键冲突时，可在这里继续修改。",
                Location = new Point(20, 170), Size = new Size(460, 76), ForeColor = Color.DimGray
            };
            var btnDefault = new Button { Name = "RestoreDefault", Text = "恢复默认", Location = new Point(20, 258), Size = new Size(104, 34), TabIndex = 2 };
            var btnOk = new Button { Name = "SaveHotkey", Text = "保存", Location = new Point(290, 258), Size = new Size(90, 34), TabIndex = 3 };
            _cancel = new Button { Name = "CancelHotkey", Text = "取消", Location = new Point(390, 258), Size = new Size(90, 34), TabIndex = 4, DialogResult = DialogResult.Cancel };

            btnDefault.Click += (s, e) =>
            {
                StopRecording();
                _input.Text = Program.DefaultHotkey;
                SetStatus("已填入默认快捷键，点击保存后生效。", false);
            };
            btnOk.Click += (s, e) => SaveChanges();
            _record.Click += (s, e) =>
            {
                if (_recording) { StopRecording(); SetStatus("录制已停止，可直接输入快捷键。", false); }
                else BeginRecording();
            };
            _input.TextChanged += (s, e) =>
            {
                UpdatePendingHotkey();
                if (!_recording) SetStatus("修改后点击保存。快捷键冲突时，可在这里继续修改。", false);
            };
            Controls.AddRange(new Control[] { tip, _cur, inputLabel, _input, _record, _status, btnDefault, btnOk, _cancel });
            UpdatePendingHotkey();
            AcceptButton = btnOk;
            CancelButton = _cancel;
            ActiveControl = _input;
        }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (!_recording) return base.ProcessCmdKey(ref message, keyData);
            if (keyData == Keys.Tab || keyData == (Keys.Shift | Keys.Tab))
            {
                StopRecording();
                SetStatus("录制已停止，可直接输入快捷键。", false);
                return base.ProcessCmdKey(ref message, keyData);
            }
            var key = new KeyEventArgs(keyData);
            HandleRecordingKey(key);
            return key.Handled || base.ProcessCmdKey(ref message, keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (_recording) HandleRecordingKey(e);
            if (!e.Handled) base.OnKeyDown(e);
        }

        private void BeginRecording()
        {
            _recording = true;
            _input.ReadOnly = true;
            _record.Text = "停止录制";
            SetStatus("请按 Ctrl / Alt / Shift + 一个按键。Esc 退出录制，Tab 切换控件。", false);
        }

        private void StopRecording()
        {
            _recording = false;
            _input.ReadOnly = false;
            _record.Text = "录制快捷键";
        }

        private void HandleRecordingKey(KeyEventArgs e)
        {
            Keys k = e.KeyCode;
            if (e.KeyData == Keys.Escape)
            {
                StopRecording();
                SetStatus("已取消录制，待保存的快捷键未改变。", false);
                e.SuppressKeyPress = true;
                return;
            }
            if (e.KeyData == Keys.Tab || e.KeyData == (Keys.Shift | Keys.Tab)) { StopRecording(); return; }
            // 忽略单独的修饰键,等真正的键
            if (k == Keys.ControlKey || k == Keys.Menu || k == Keys.ShiftKey ||
                k == Keys.LControlKey || k == Keys.RControlKey ||
                k == Keys.LMenu || k == Keys.RMenu ||
                k == Keys.LShiftKey || k == Keys.RShiftKey ||
                k == Keys.LWin || k == Keys.RWin)
            {
                e.Handled = true;
                return;
            }

            KeyModifiers m = KeyModifiers.None;
            if (e.Control) m |= KeyModifiers.Control;
            if (e.Alt) m |= KeyModifiers.Alt;
            if (e.Shift) m |= KeyModifiers.Shift;

            if (m == KeyModifiers.None)
            {
                SetStatus("请至少加一个修饰键：Ctrl / Alt / Shift。", true);
                e.SuppressKeyPress = true;
                return;
            }

            if (!Program.IsValidHotkeyKey(k)) { SetStatus("此按键无法注册，请换一个组合（F12 为系统保留键）。", true); e.SuppressKeyPress = true; return; }
            _input.Text = Program.HotkeyToString(m, k);
            StopRecording();
            SetStatus("已录制 " + Program.HotkeyToDisplay(m, k) + "，点击保存后生效。", false);
            e.SuppressKeyPress = true;
        }

        private void UpdatePendingHotkey()
        {
            KeyModifiers mods; Keys key;
            if (Program.TryParseHotkey(_input.Text, out mods, out key)) { ResultMods = mods; ResultKey = key; }
            else { ResultMods = KeyModifiers.None; ResultKey = Keys.None; }
        }

        private bool SaveChanges()
        {
            StopRecording();
            KeyModifiers mods; Keys key;
            if (!Program.TryParseHotkey(_input.Text, out mods, out key))
            {
                SetStatus("快捷键格式无效。请输入 Ctrl / Alt / Shift / Win + 一个有效按键，例如 Ctrl+Alt+A；F12 为系统保留键。", true);
                _input.Focus();
                _input.SelectAll();
                return false;
            }
            ResultMods = mods;
            ResultKey = key;
            HotkeySaveResult result;
            try
            {
                result = _saveHotkey == null ? new HotkeySaveResult(false, true, null) : _saveHotkey(mods, key);
                if (result == null) result = new HotkeySaveResult(false, false, "保存未完成，请重试。");
            }
            catch (Exception error) { result = new HotkeySaveResult(false, false, "保存失败：" + error.Message); }
            if (result.Applied) _cur.Text = "当前生效：" + Program.HotkeyToDisplay(mods, key);
            if (!result.Saved)
            {
                if (result.Applied) _cancel.Text = "关闭";
                SetStatus(result.Message ?? "保存失败，请修改后重试。", true);
                return false;
            }
            DialogResult = DialogResult.OK;
            Close();
            return true;
        }

        private void SetStatus(string text, bool error)
        {
            _status.Text = text;
            _status.ForeColor = error ? Color.Firebrick : Color.DimGray;
        }

        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing)
            {
                _headingFont.Dispose();
                _normalFont.Dispose();
            }
        }
    }

    /// <summary>延迟截图倒计时浮窗。</summary>
    internal sealed class CountdownForm : Form
    {
        private int _seconds;
        private bool _aborted;
        private readonly Timer _timer;
        private Timer _settleTimer;

        public CountdownForm(int seconds)
        {
            _seconds = seconds;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            ClientSize = new Size(120, 120);
            BackColor = Color.Fuchsia;
            TransparencyKey = Color.Fuchsia;
            var area = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(area.Right - 150, area.Bottom - 150);
            Cursor = Cursors.Hand;
            _timer = new Timer { Interval = 1000 };
            _timer.Tick += (s, e) => Tick();
        }

        protected override void OnLoad(EventArgs e) { base.OnLoad(e); _timer.Start(); Invalidate(); }

        internal void ForceCancel() { _aborted = true; _timer.Stop(); Close(); }

        private void Tick()
        {
            _seconds--;
            if (_seconds > 0) { Invalidate(); return; }
            // 倒计时结束:先隐藏自己,等屏幕重绘完成后再截图,避免把倒计时圆圈截进画面
            _timer.Stop();
            Visible = false;
            var t = _settleTimer = new Timer { Interval = 250 };
            t.Tick += (s, e2) =>
            {
                t.Stop(); t.Dispose();
                _settleTimer = null;
                if (IsDisposed) return;
                Close();
                if (!_aborted) Program.StartCapture();
            };
            t.Start();
        }

        protected override void OnClick(EventArgs e) { _aborted = true; _timer.Stop(); Close(); base.OnClick(e); }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _timer.Dispose();
                if (_settleTimer != null) _settleTimer.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(4, 4, 112, 112);
            using (var b = new SolidBrush(Color.FromArgb(225, 30, 30, 45))) g.FillEllipse(b, r);
            using (var p = new Pen(Color.White, 3)) g.DrawEllipse(p, r);
            using (var font = new Font("Segoe UI", 44, FontStyle.Bold))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                var shadow = new RectangleF(r.X + 2, r.Y + 2, r.Width, r.Height);
                g.DrawString(_seconds.ToString(), font, Brushes.Black, shadow, sf);
                g.DrawString(_seconds.ToString(), font, Brushes.White, r, sf);
            }
            using (var font2 = new Font("Microsoft YaHei UI", 9))
            using (var sf2 = new StringFormat { Alignment = StringAlignment.Center })
            {
                g.DrawString("点击取消", font2, Brushes.WhiteSmoke, new RectangleF(r.X, r.Bottom - 22, r.Width, 18), sf2);
            }
        }
    }

    internal sealed class HotKeyWindow : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string caption);
        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

        private const int WM_HOTKEY = 0x0312;
        private const int WM_CAPTURE = 0x8001;
        private const int HotKeyId = 0x9001;
        private int _activeId;
        private Keys _key;
        private KeyModifiers _modifiers;
        public event EventHandler HotKeyPressed;

        public HotKeyWindow()
        {
            var cp = new CreateParams { Caption = "SnapToolHotKeyWindow" };
            CreateHandle(cp);
        }

        public bool Register(Keys key, KeyModifiers modifiers)
        {
            if (!Program.IsValidHotkeyKey(key) || modifiers == KeyModifiers.None) return false;
            if (_activeId != 0 && _key == key && _modifiers == modifiers) return true;
            int next = _activeId == HotKeyId ? HotKeyId + 1 : HotKeyId;
            if (!RegisterHotKey(Handle, next, (uint)modifiers | 0x4000, (uint)key)) return false;
            Unregister();
            _activeId = next; _key = key; _modifiers = modifiers;
            return true;
        }
        public void Unregister()
        {
            if (_activeId != 0) UnregisterHotKey(Handle, _activeId);
            _activeId = 0;
        }
        public void Dispose() { Unregister(); DestroyHandle(); }
        internal static void RequestCapture()
        {
            IntPtr window = FindWindow(null, "SnapToolHotKeyWindow");
            if (window != IntPtr.Zero) PostMessage(window, WM_CAPTURE, IntPtr.Zero, IntPtr.Zero);
        }

        protected override void WndProc(ref Message m)
        {
            if ((m.Msg == WM_CAPTURE || (m.Msg == WM_HOTKEY && (int)m.WParam == _activeId)) && HotKeyPressed != null)
                HotKeyPressed(this, EventArgs.Empty);
            base.WndProc(ref m);
        }
    }

    [Flags]
    internal enum KeyModifiers : uint { None = 0, Alt = 1, Control = 2, Shift = 4, WindowsKey = 8 }
}
