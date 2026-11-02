using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class StableLauncher
{
    internal const string AppId = "SheetMusicReader.Desktop";
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(uint processId);

    private static readonly string[] LegacyMembers = {
        "dartjni.dll", "file_selector_windows_plugin.dll", "flutter_windows.dll",
        "native_assets.json", "pdfium.dll", "pdfrx_pdfium_gate.dll", "score_reader.exe",
        "url_launcher_windows_plugin.dll", "data\\app.so", "data\\icudtl.dat",
        "data\\flutter_assets\\AssetManifest.bin", "data\\flutter_assets\\FontManifest.json",
        "data\\flutter_assets\\NativeAssetsManifest.json", "data\\flutter_assets\\NOTICES.Z",
        "data\\flutter_assets\\fonts\\MaterialIcons-Regular.otf",
        "data\\flutter_assets\\packages\\material_ui\\shaders\\ink_sparkle.frag",
        "data\\flutter_assets\\shaders\\ink_sparkle.frag",
        "data\\flutter_assets\\shaders\\stretch_effect.frag"
    };

    private static string ValidateRelease(Dictionary<string, object> deployment, string directory,
        JavaScriptSerializer serializer, bool verifyHashes)
    {
        string version = (string)deployment["version"];
        if (!Regex.IsMatch(version, @"^\d+\.\d+\.\d+\+\d+$"))
            throw new InvalidDataException("Invalid release version.");
        string profile = deployment.ContainsKey("layoutProfile") ? (string)deployment["layoutProfile"] : "legacy";
        if (profile != "legacy" && profile != "share-v1") throw new InvalidDataException("Unknown release layout profile.");
        if (profile == "legacy" && new Version(version.Replace('+', '.')) >= new Version(0, 8, 10, 31))
            throw new InvalidDataException("Release 0.8.10+31 and later requires share-v1.");
        var expected = new HashSet<string>(LegacyMembers, StringComparer.OrdinalIgnoreCase);
        if (profile == "share-v1") expected.Add("share_plus_plugin.dll");
        var members = serializer.ConvertToType<string[]>(deployment["members"]);
        if (members.Length != expected.Count || !expected.SetEquals(members))
            throw new InvalidDataException("Release members do not match the layout profile.");
        // Walk only after rejecting each directory link, so verification never follows a junction.
        var actual = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.Count != 0)
        {
            string current = pending.Pop();
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Release contains a reparse point.");
            foreach (string path in Directory.GetFileSystemEntries(current))
            {
                FileAttributes attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Release contains a reparse point.");
                if ((attributes & FileAttributes.Directory) != 0) pending.Push(path);
                else
                {
                    string relative = path.Substring(directory.TrimEnd(Path.DirectorySeparatorChar).Length + 1);
                    if (!expected.Contains(relative) || new FileInfo(path).Length == 0)
                        throw new InvalidDataException("Unexpected or empty release member.");
                    actual.Add(relative);
                }
            }
        }
        if (!expected.SetEquals(actual)) throw new InvalidDataException("Release member is missing.");
        if (FileVersionInfo.GetVersionInfo(Path.Combine(directory, "score_reader.exe")).ProductVersion != version)
            throw new InvalidDataException("Executable product version does not match the deployment.");
        if (profile == "share-v1")
        {
            var hashes = serializer.ConvertToType<Dictionary<string, string>>(deployment["sha256"]);
            if (hashes.Count != expected.Count || !expected.SetEquals(hashes.Keys))
                throw new InvalidDataException("Release hash manifest does not match the layout.");
            foreach (string member in members)
            {
                if (!Regex.IsMatch(hashes[member], "^[a-fA-F0-9]{64}$"))
                    throw new InvalidDataException("Invalid release SHA256.");
                if (verifyHashes)
                {
                    using (var stream = File.OpenRead(Path.Combine(directory, member)))
                    using (var algorithm = SHA256.Create())
                    {
                        string digest = BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "");
                        if (!String.Equals(digest, hashes[member], StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Release SHA256 mismatch.");
                    }
                }
            }
        }
        return profile;
    }

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
            string profile = null;
            if (!inspect || args[0] == "--verify") profile = ValidateRelease(deployment, directory, serializer, inspect);
            if (inspect)
            {
                string json = serializer.Serialize(new { ok = true, appId = AppId,
                    version = deployment["version"], executable = executable, pointer = pointer, layoutProfile = profile });
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
