using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace SnapTool
{
    internal static class SettingsTests
    {
        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        private static object Call(SettingsForm form, string method, params object[] args)
        {
            return typeof(SettingsForm).GetMethod(method, Private).Invoke(form, args);
        }

        private static T ControlNamed<T>(SettingsForm form, string name) where T : Control
        {
            return (T)form.Controls[name];
        }

        private static SettingsForm Open(string initial, Func<KeyModifiers, Keys, HotkeySaveResult> save)
        {
            var form = new SettingsForm(initial, save)
            {
                TopMost = false, StartPosition = FormStartPosition.Manual,
                Location = new Point(-20000, -20000)
            };
            form.Show();
            Application.DoEvents();
            return form;
        }

        private static bool Save(SettingsForm form) { return (bool)Call(form, "SaveChanges"); }
        private static bool Command(SettingsForm form, Keys keys)
        {
            return (bool)Call(form, "ProcessCmdKey", new Message(), keys);
        }

        private static void Preview(SettingsForm form, string path)
        {
            using (var bitmap = new Bitmap(form.Width, form.Height))
            {
                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                bitmap.Save(path, ImageFormat.Png);
            }
        }

        internal static void Run(Action<bool, string> check, string folder)
        {
            Directory.CreateDirectory(folder);
            KeyModifiers mods; Keys key;
            foreach (string input in new[] { "Ctrl+Esc", "Ctrl+PgUp", "Alt+PgDn", "Ctrl+Del", "Shift+空格", "Ctrl+Enter" })
                check(Program.TryParseHotkey(input, out mods, out key), "settings parse common key alias " + input);
            foreach (string input in new[] { "Ctrl+Ctrl+A", "Ctrl+Control+A", "Win+Windows+A", "Ctrl+Bogus+A", "Ctrl+LButton", "Ctrl+F12" })
                check(!Program.TryParseHotkey(input, out mods, out key), "settings reject invalid or duplicate input " + input);

            int calls = 0;
            Func<KeyModifiers, Keys, HotkeySaveResult> successful = (m, k) =>
            {
                calls++;
                return new HotkeySaveResult(true, true, null);
            };
            using (var form = Open("Ctrl+1", successful))
            {
                var input = ControlNamed<TextBox>(form, "HotkeyInput");
                var current = ControlNamed<Label>(form, "CurrentHotkey");
                check(current.Text.Contains("Ctrl + 1"), "settings clearly show currently effective shortcut");
                check(!input.ReadOnly && !(bool)typeof(SettingsForm).GetField("_recording", Private).GetValue(form), "settings starts in ordinary text editing mode");
                Preview(form, Path.Combine(folder, "settings-preview.png"));
                var normal = new KeyEventArgs(Keys.A);
                Call(form, "OnKeyDown", normal);
                check(!normal.Handled && form.ResultKey == Keys.D1, "ordinary letters are not swallowed as shortcut recording");
                Command(form, Keys.Control | Keys.Tab);
                check(form.ResultKey == Keys.D1, "modified dialog keys are not recorded until recording is requested");
                input.Clear();
                input.AppendText(" Ctrl + Shift + 7 ");
                check(input.Text == " Ctrl + Shift + 7 " && form.ResultMods == (KeyModifiers.Control | KeyModifiers.Shift) && form.ResultKey == Keys.D7,
                    "actual textbox edits update pending parsed shortcut");
                check(current.Text.Contains("Ctrl + 1") && calls == 0, "editing text does not apply or save shortcut");
                Call(form, "BeginRecording");
                check(input.ReadOnly, "explicit recording temporarily locks text input");
                Command(form, Keys.Tab);
                check(!input.ReadOnly && form.ResultKey == Keys.D7, "Tab ends recording and preserves pending shortcut");
                Call(form, "BeginRecording");
                check(Command(form, Keys.Escape) && !input.ReadOnly && !form.IsDisposed && form.DialogResult == DialogResult.None,
                    "Escape exits recording without cancelling settings");
                Call(form, "BeginRecording");
                check(Command(form, Keys.Control | Keys.Tab) && form.ResultKey == Keys.Tab && !input.ReadOnly,
                    "explicit recording accepts Ctrl+Tab and returns to text editing");
                Call(form, "BeginRecording");
                var invalid = new KeyEventArgs(Keys.Control | Keys.F12);
                Call(form, "OnKeyDown", invalid);
                check(invalid.SuppressKeyPress && form.ResultKey == Keys.Tab && ControlNamed<Label>(form, "HotkeyStatus").Text.Contains("F12"),
                    "reserved key recording shows error and retains prior choice");
                Call(form, "StopRecording");
                ControlNamed<Button>(form, "RestoreDefault").PerformClick();
                check(input.Text == Program.DefaultHotkey && form.ResultKey == Keys.A && calls == 0,
                    "restore default fills pending shortcut without applying it");
            }

            using (var form = Open("Ctrl+1", successful))
            {
                var input = ControlNamed<TextBox>(form, "HotkeyInput");
                foreach (string invalid in new[] { "", "A", "Ctrl+", "Ctrl+F12", "Ctrl+Ctrl+A", "Ctrl+Bogus+A", "Ctrl+LButton" })
                {
                    input.Text = invalid;
                    check(!Save(form) && !form.IsDisposed && form.DialogResult == DialogResult.None && calls == 0,
                        "invalid shortcut stays editable and never reaches registration: " + invalid);
                }
                input.Text = "Ctrl+Shift+7";
                Call(form, "ProcessDialogKey", Keys.Enter);
                check(calls == 1 && form.DialogResult == DialogResult.OK, "Enter in ordinary editing mode saves validated input");
            }
            using (var form = Open("Ctrl+1", successful))
            {
                Call(form, "ProcessDialogKey", Keys.Escape);
                check(form.DialogResult == DialogResult.Cancel && calls == 1, "Escape in ordinary editing mode cancels without saving");
            }

            string active = "Ctrl+D1";
            string file = Path.Combine(folder, "settings-callback-config-" + Guid.NewGuid().ToString("N") + ".txt");
            int attempts = 0;
            bool blockedConfig = false;
            Func<KeyModifiers, Keys, HotkeySaveResult> backend = (m, k) =>
            {
                attempts++;
                if (k == Keys.F10) return new HotkeySaveResult(false, false, "快捷键已被其他程序占用，原快捷键仍然有效。");
                active = Program.HotkeyToString(m, k);
                if (blockedConfig) return new HotkeySaveResult(true, false, "配置保存失败，新快捷键仅临时生效。关闭后仍可使用，重启后恢复原配置。请重试保存或改回原快捷键。");
                File.WriteAllText(file, active);
                return new HotkeySaveResult(true, true, null);
            };
            using (var form = Open("Ctrl+1", backend))
            {
                var input = ControlNamed<TextBox>(form, "HotkeyInput");
                input.Text = "Ctrl+F10";
                check(!Save(form) && active == "Ctrl+D1" && !File.Exists(file) && !form.IsDisposed,
                    "conflict retains active original shortcut and settings dialog");
                check(ControlNamed<Label>(form, "HotkeyStatus").Text.Contains("占用") && ControlNamed<Label>(form, "CurrentHotkey").Text.Contains("Ctrl + 1"),
                    "conflict error is visible while current effective label stays unchanged");
                Preview(form, Path.Combine(folder, "settings-conflict-preview.png"));
                input.Text = "Ctrl+Alt+P";
                check(Save(form) && active == "Ctrl+Alt+P" && File.ReadAllText(file) == active && attempts == 2,
                    "correcting conflict applies then saves successfully in same dialog");
            }
            blockedConfig = true;
            using (var form = Open(active, backend))
            {
                var input = ControlNamed<TextBox>(form, "HotkeyInput");
                input.Text = "Ctrl+Shift+S";
                check(!Save(form) && active == "Ctrl+Shift+S" && form.DialogResult == DialogResult.None && !form.IsDisposed,
                    "configuration failure never reports save success or closes settings");
                check(ControlNamed<Label>(form, "CurrentHotkey").Text.Contains("Ctrl + Shift + S") && ControlNamed<Button>(form, "CancelHotkey").Text == "关闭" &&
                    ControlNamed<Label>(form, "HotkeyStatus").Text.Contains("临时"),
                    "configuration failure clearly identifies temporary effective shortcut");
                check(File.ReadAllText(file) == "Ctrl+Alt+P", "configuration failure keeps prior persisted shortcut intact");
                Preview(form, Path.Combine(folder, "settings-temporary-preview.png"));
                blockedConfig = false;
                check(Save(form) && File.ReadAllText(file) == "Ctrl+Shift+S", "retry can persist temporary shortcut without leaving settings");
            }
            using (var form = Open("Ctrl+1", (m, k) => { throw new IOException("模拟保存异常"); }))
            {
                check(!Save(form) && !form.IsDisposed && ControlNamed<Label>(form, "HotkeyStatus").Text.Contains("保存失败"),
                    "unexpected backend exception remains visible and editable");
            }
            check(typeof(Program).GetMethod("OpenSettings", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(Form) }, null) != null,
                "capture screen can open settings with an owner");
            check(typeof(Program).GetMethod("OpenSettings", BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null) != null,
                "tray settings entry remains supported");
        }
    }
}
