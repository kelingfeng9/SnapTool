using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SnapTool
{
    // A fallback must remain readable even when an older portable file still exists.
    internal sealed class ConfigurationStore
    {
        private readonly string _portablePath, _fallbackPath;
        public ConfigurationStore(string portablePath, string fallbackPath)
        {
            _portablePath = portablePath;
            _fallbackPath = fallbackPath;
        }

        private string ActivePath()
        {
            if (File.Exists(_fallbackPath) && (!File.Exists(_portablePath) ||
                File.GetLastWriteTimeUtc(_fallbackPath) > File.GetLastWriteTimeUtc(_portablePath)))
                return _fallbackPath;
            return _portablePath;
        }

        private Dictionary<string, string> Read()
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string[] lines;
            string path = ActivePath();
            try { lines = File.ReadAllLines(path, Encoding.UTF8); }
            catch (IOException) { lines = ReadOther(path); }
            catch (UnauthorizedAccessException) { lines = ReadOther(path); }
            foreach (string raw in lines)
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";")) continue;
                int eq = line.IndexOf('=');
                if (eq > 0) values[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                else if (eq < 0 && !values.ContainsKey("hotkey")) values["hotkey"] = line;
            }
            return values;
        }

        private string[] ReadOther(string path)
        {
            try { return File.ReadAllLines(path == _portablePath ? _fallbackPath : _portablePath, Encoding.UTF8); }
            catch (IOException) { return new string[0]; }
            catch (UnauthorizedAccessException) { return new string[0]; }
        }

        public string Get(string key)
        {
            string value;
            return Read().TryGetValue(key, out value) ? value : null;
        }

        public void Set(string key, string value)
        {
            var values = Read();
            values[key] = value ?? "";
            var data = new StringBuilder();
            foreach (var entry in values) data.Append(entry.Key).Append('=').Append(entry.Value).Append("\r\n");
            string path = ActivePath();
            try { WriteAtomic(path, data.ToString()); }
            catch (IOException) { if (path == _fallbackPath) throw; WriteAtomic(_fallbackPath, data.ToString()); }
            catch (UnauthorizedAccessException) { if (path == _fallbackPath) throw; WriteAtomic(_fallbackPath, data.ToString()); }
        }

        private static void WriteAtomic(string path, string data)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, data, new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
}
