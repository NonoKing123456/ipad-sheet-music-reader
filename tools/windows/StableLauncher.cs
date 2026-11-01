using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class StableLauncher
{
    internal const string AppId = "SheetMusicReader.Desktop";
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(uint processId);

    // Exactly the Windows command-line quoting rules, including trailing slashes.
    private static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1).Append('"');
            else result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool inspect = args.Length > 0 && (args[0] == "--resolve-only" || args[0] == "--verify");
        string output = null;
        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppId);
            string pointer = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "deployment.json");
            if (inspect)
            {
                for (int i = 1; i < args.Length; i++)
                {
                    if (args[i] == "--output" && i + 1 < args.Length) output = Path.GetFullPath(args[++i]);
                    else if (args[i] == "--pointer" && i + 1 < args.Length) pointer = Path.GetFullPath(args[++i]);
                    else throw new ArgumentException("Unknown verification option.");
                }
            }
            var serializer = new JavaScriptSerializer();
            var deployment = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(pointer, Encoding.UTF8));
            if ((string)deployment["appId"] != AppId) throw new InvalidDataException("Invalid application identity.");
            string directory = (string)deployment["releaseDirectory"];
            if (!Path.IsPathRooted(directory)) throw new InvalidDataException("Deployment path must be absolute.");
            directory = Path.GetFullPath(directory);
            string executable = Path.Combine(directory, "score_reader.exe");
            if (!File.Exists(executable)) throw new FileNotFoundException("Release executable is missing.");
            if (inspect)
            {
                if (args[0] == "--verify")
                {
                    var files = serializer.ConvertToType<string[]>(deployment["members"]);
                    if (files.Length != 18) throw new InvalidDataException("Expected 18 release members.");
                    foreach (object member in files)
                    {
                        string path = Path.GetFullPath(Path.Combine(directory, (string)member));
                        if (!path.StartsWith(directory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                            !File.Exists(path) || new FileInfo(path).Length == 0)
                            throw new InvalidDataException("Release member is missing or invalid.");
                    }
                }
                string json = serializer.Serialize(new { ok = true, appId = AppId,
                    version = deployment["version"], executable = executable, pointer = pointer });
                if (output != null) File.WriteAllText(output, json, new UTF8Encoding(false));
                else { AttachConsole(0xffffffff); Console.WriteLine(json); }
                return 0;
            }
            var quoted = new List<string>();
            foreach (string arg in args) quoted.Add(Quote(arg));
            Process.Start(new ProcessStartInfo(executable, String.Join(" ", quoted.ToArray())) {
                WorkingDirectory = directory, UseShellExecute = false
            });
            return 0;
        }
        catch (Exception error)
        {
            if (inspect)
            {
                string json = new JavaScriptSerializer().Serialize(new { ok = false, error = error.Message });
                if (output != null) File.WriteAllText(output, json, new UTF8Encoding(false));
                else { AttachConsole(0xffffffff); Console.Error.WriteLine(json); }
            }
            else MessageBox.Show("曲谱阅读器暂时无法打开，请重新运行本地发布脚本。", "曲谱阅读器", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
