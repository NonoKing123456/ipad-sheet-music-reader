using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

public static class ShortcutIdentity
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid format; public uint id;
        public PropertyKey(uint value) { format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); id = value; } }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant { [FieldOffset(0)] public ushort type; [FieldOffset(8)] public IntPtr text; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count); void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value); void Commit();
    }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink {}
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLink {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int max, IntPtr find, uint flags);
        void GetIDList(out IntPtr list); void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey); void SetHotkey(short hotkey);
        void GetShowCmd(out int command); void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder icon, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string icon, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    static void Set(IPropertyStore store, uint id, string text) {
        var key = new PropertyKey(id);
        var value = new PropVariant { type = 31, text = Marshal.StringToCoTaskMemUni(text) };
        try { store.SetValue(ref key, ref value); } finally { PropVariantClear(ref value); }
    }
    static string Read(IPropertyStore store, uint id) {
        var key = new PropertyKey(id); PropVariant value; store.GetValue(ref key, out value);
        try { return value.type == 31 ? Marshal.PtrToStringUni(value.text) : null; }
        finally { PropVariantClear(ref value); }
    }
    public static void Create(string shortcut, string target, string icon) {
        object instance = new ShellLink();
        try {
            var link = (IShellLink)instance; link.SetPath(target); link.SetArguments("");
            link.SetWorkingDirectory(System.IO.Path.GetDirectoryName(target));
            link.SetDescription("曲谱阅读器"); link.SetIconLocation(icon, 0); link.SetShowCmd(1);
            var store = (IPropertyStore)instance;
            Set(store, 5, "SheetMusicReader.Desktop");
            Set(store, 2, "\"" + target + "\"");
            Set(store, 4, "@" + target + ",-101"); Set(store, 3, icon + ",0");
            store.Commit(); ((IPersistFile)instance).Save(shortcut, true);
        } finally { Marshal.FinalReleaseComObject(instance); }
    }
    public static string[] Inspect(string shortcut) {
        object instance = new ShellLink();
        try {
            ((IPersistFile)instance).Load(shortcut, 0);
            var path = new StringBuilder(32768); ((IShellLink)instance).GetPath(path, path.Capacity, IntPtr.Zero, 4);
            var store = (IPropertyStore)instance;
            return new [] { path.ToString(), Read(store, 5), Read(store, 2), Read(store, 4), Read(store, 3) };
        } finally { Marshal.FinalReleaseComObject(instance); }
    }
}
