// Native process supervision: create suspended, assign a kill-on-close job, then
// resume. Descendants cannot outlive the launcher, including during Ctrl+C.
using System;
using System.Collections;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class DriveChild {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Startup { public int cb; public string reserved, desktop, title; public int x,y,w,h,cx,cy,fill,flags; public short show, reserved2; public IntPtr bytes, stdin, stdout, stderr; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit { public long processTime, jobTime; public uint flags; public UIntPtr min,max; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong r,w,o,rb,wb,ob; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit { public BasicLimit basic; public Io io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateDirectory(string path, IntPtr attributes);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimit info, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static string Quote(string value) {
        if (value == null) value = String.Empty;
        var b = new StringBuilder("\""); int slashes=0;
        foreach (char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='"') b.Append('\\',slashes*2+1); else b.Append('\\',slashes);
            b.Append(c); slashes=0;
        }
        b.Append('\\',slashes*2); b.Append('"'); return b.ToString();
    }
    public static int Run(string app, string[] args, IDictionary env, string cwd) {
        var command = new StringBuilder(Quote(app));
        foreach(string arg in args ?? new string[0]) command.Append(" ").Append(Quote(arg));
        var keys = new System.Collections.Generic.List<string>(); foreach(string key in env.Keys) keys.Add(key);
        keys.Sort(StringComparer.OrdinalIgnoreCase);
        var block = new StringBuilder(); foreach(string key in keys) block.Append(key).Append('=').Append(env[key]).Append('\0'); block.Append('\0');
        IntPtr environment = Marshal.StringToHGlobalUni(block.ToString());
        IntPtr job = IntPtr.Zero; ProcessInfo info = new ProcessInfo();
        try {
            job = CreateJobObject(IntPtr.Zero,null); Check(job!=IntPtr.Zero);
            var limits = new ExtendedLimit(); limits.basic.flags=0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(limits)));
            var startup = new Startup(); startup.cb=Marshal.SizeOf(startup);
            Check(CreateProcess(app,command,IntPtr.Zero,IntPtr.Zero,true,0x404,environment,cwd,ref startup,out info)); // suspended + unicode environment
            Check(AssignProcessToJobObject(job,info.process));
            Check(ResumeThread(info.thread)!=0xffffffff);
            Check(WaitForSingleObject(info.process,0xffffffff)==0);
            uint code; Check(GetExitCodeProcess(info.process,out code)); return unchecked((int)code);
        } finally {
            if(info.process!=IntPtr.Zero) { TerminateProcess(info.process,1); CloseHandle(info.process); }
            if(info.thread!=IntPtr.Zero) CloseHandle(info.thread);
            if(job!=IntPtr.Zero) CloseHandle(job);
            Marshal.FreeHGlobal(environment);
        }
    }
}
