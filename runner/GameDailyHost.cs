using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Collections.Generic;
using System.Windows.Forms;
using System.Drawing;

namespace GameDaily {
    // A suspended launch is assigned before its first instruction. Descendants inherit
    // membership, including detached GUI processes; closing the handle kills members.
    public sealed class ProcessGroup : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct IO { public ulong a,b,c,d,e,f; }
        [StructLayout(LayoutKind.Sequential)] struct Basic { public long a,b; public uint flags; public UIntPtr c,d; public uint e; public UIntPtr f; public uint g,h; }
        [StructLayout(LayoutKind.Sequential)] struct Limits { public Basic basic; public IO io; public UIntPtr a,b,c,d; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
            public uint cb; public string reserved,desktop,title; public uint x,y,w,h,cx,cy,fill,flags;
            public ushort show,reserved2; public IntPtr reservedPtr,input,output,error;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr p,string name);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j,int c,ref Limits v,uint n);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr j,int c,IntPtr data,uint n,out uint returned);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr j,uint code);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr p,IntPtr t,bool inherit,uint flags,IntPtr env,string cwd,ref Startup start,out ProcessInfo info);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr t);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p,uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        IntPtr job;
        public ProcessGroup() {
            job=CreateJobObject(IntPtr.Zero,null);
            if(job==IntPtr.Zero) throw new Win32Exception();
            var limits=new Limits(); limits.basic.flags=0x2000; // KILL_ON_JOB_CLOSE; no breakaway.
            if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(Limits)))) { Dispose(); throw new Win32Exception(); }
        }
        public static string Quote(string s) {
            if(s==null) return "\"\"";
            // Paths/arguments are local structured values, never a shell command.
            return "\""+s.Replace("\"","\\\"")+"\"";
        }
        public Process Launch(string exe,string args,string cwd) {
            var si=new Startup(); si.cb=(uint)Marshal.SizeOf(typeof(Startup));
            ProcessInfo pi;
            if(!CreateProcess(exe,new StringBuilder(Quote(exe)+" "+args),IntPtr.Zero,IntPtr.Zero,false,0x08000004,IntPtr.Zero,cwd,ref si,out pi)) throw new Win32Exception();
            try {
                if(!AssignProcessToJobObject(job,pi.process)) { var err=Marshal.GetLastWin32Error(); TerminateProcess(pi.process,1); throw new Win32Exception(err,"无法纳管子进程，本轮未启动。"); }
                var p=Process.GetProcessById((int)pi.pid); var handle=p.Handle;
                if(ResumeThread(pi.thread)==0xffffffff) { TerminateProcess(pi.process,1); throw new Win32Exception(); }
                return p;
            } finally { CloseHandle(pi.thread); CloseHandle(pi.process); }
        }
        public int[] Members() {
            int size=65536; IntPtr data=Marshal.AllocHGlobal(size);
            try {
                uint returned;
                if(!QueryInformationJobObject(job,3,data,(uint)size,out returned)) throw new Win32Exception();
                int count=Marshal.ReadInt32(data,4); var ids=new List<int>();
                for(int i=0;i<count;i++) ids.Add((int)Marshal.ReadIntPtr(data,8+i*IntPtr.Size));
                return ids.ToArray();
            } finally { Marshal.FreeHGlobal(data); }
        }
        public void Kill() { if(job!=IntPtr.Zero && !TerminateJobObject(job,130)) throw new Win32Exception(); }
        public void Dispose() { if(job!=IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; } }
    }

    public sealed class DailyWindow : Form {
        readonly string exe,root,control,game,resume,config;
        readonly ProcessGroup group=new ProcessGroup();
        Process worker,stopper,finisher;
        ProcessGroup finishGroup;
        readonly Label status=new Label(), detail=new Label();
        readonly Button report=new Button();
        readonly Timer timer=new Timer();
        readonly Stopwatch elapsed=Stopwatch.StartNew();
        DateTime closeAt,finishAt;
        bool stopping,finalizing,finished,allowClose,failed;
        int testCloseMs;
        public int ResultCode;
        void Log(string text) { File.AppendAllText(Path.Combine(control,"supervisor.log"),DateTimeOffset.Now.ToString("o")+" "+text+Environment.NewLine,Encoding.UTF8); }
        void Put(string name,string text) { File.WriteAllText(Path.Combine(control,name),text,new UTF8Encoding(false)); }
        string ScriptArgs(string file) { return "-NoProfile -STA -ExecutionPolicy Bypass -File "+ProcessGroup.Quote(Path.Combine(root,file))+" -ControlDirectory "+ProcessGroup.Quote(control); }
        public DailyWindow(string hostExe,string folder,string directory,string selected,string resumeDir,string configPath,string icon,int autoClose) {
            exe=hostExe; root=folder;control=directory;game=selected;resume=resumeDir;config=configPath;testCloseMs=autoClose;
            Text="每日上班"; ClientSize=new Size(540,218); FormBorderStyle=FormBorderStyle.FixedSingle; MaximizeBox=false;
            StartPosition=FormStartPosition.CenterScreen; Font=new Font("Microsoft YaHei UI",10);
            if(File.Exists(icon)) Icon=new Icon(icon);
            status.SetBounds(22,20,496,32); status.Font=new Font(Font.FontFamily,14,FontStyle.Bold); status.Text="正在准备日常…";
            detail.SetBounds(22,62,496,74); detail.Text="按原神 → 星铁 → 终末地执行。\n运行时请保持游戏前台、键鼠空闲。\n关闭本窗口会停止本轮任务并退出本轮启动的程序。";
            report.SetBounds(22,151,140,36); report.Text="查看本轮记录";
            report.Click+=(s,e)=> { string p=Path.Combine(control,"report.html"); Process.Start(new ProcessStartInfo(File.Exists(p)?p:control){UseShellExecute=true}); };
            var minimize=new Button(); minimize.SetBounds(178,151,140,36); minimize.Text="最小化"; minimize.Click+=(s,e)=>WindowState=FormWindowState.Minimized;
            Controls.AddRange(new Control[]{status,detail,report,minimize});
            FormClosing+=OnClosing; Shown+=OnShown; timer.Interval=500; timer.Tick+=Tick;
        }
        void OnShown(object sender,EventArgs e) {
            try {
                string args=ScriptArgs("Invoke-GameDailyWorker.ps1")+" -Game "+game+" -ConfigPath "+ProcessGroup.Quote(config);
                if(!String.IsNullOrEmpty(resume)) args+=" -ResumeRunDirectory "+ProcessGroup.Quote(resume);
                worker=group.Launch(exe,args,root); Put("worker.pid",worker.Id.ToString()); Log("Worker assigned to Windows job: "+worker.Id); timer.Start();
            } catch(Exception ex) { failed=true;ResultCode=1;Log(ex.ToString());BeginFinalize();timer.Start(); }
        }
        void Snapshot() {
            var rows=new List<string>();
            foreach(int id in group.Members()) try {
                using(var p=Process.GetProcessById(id)) rows.Add("{\"Id\":"+id+",\"StartedUtcTicks\":"+p.StartTime.ToUniversalTime().Ticks+"}");
            } catch(ArgumentException) {} catch(InvalidOperationException) {} catch(Win32Exception) {}
            Put("owned-processes.json","["+String.Join(",",rows.ToArray())+"]");
        }
        void OnClosing(object sender,FormClosingEventArgs e) {
            if(allowClose) return;
            if(finished && group.Members().Length==0) {allowClose=true;return;}
            bool completedBeforeClose=finished;
            if(finished) {finished=false;finalizing=false;}
            e.Cancel=true;
            if(stopping) return;
            stopping=true;closeAt=DateTime.UtcNow;ResultCode=130;
            status.Text="正在停止并退出…"; detail.Text="正在停止任务、关闭本轮程序并保存记录。\n通常需要几秒，请等待窗口自动关闭。";
            if(!completedBeforeClose) Put("cancel-request.json","{\"requestedAt\":\""+DateTimeOffset.Now.ToString("o")+"\",\"reason\":\"window_closed\"}");
            else ResultCode=failed?1:0;
            Log("Window close requested; no later stage may start.");
            try { Snapshot(); stopper=group.Launch(exe,ScriptArgs("Stop-GameDailyChildren.ps1")+" -ConfigPath "+ProcessGroup.Quote(config),root); }
            catch(Exception ex) {Log("Graceful stop failed: "+ex.Message);}
        }
        void BeginFinalize() {
            if(finalizing) return;
            finalizing=true;finishAt=DateTime.UtcNow;
            try {
                finishGroup=new ProcessGroup();
                finisher=finishGroup.Launch(exe,ScriptArgs("Complete-GameDailyRun.ps1")+" -ConfigPath "+ProcessGroup.Quote(config),root);
            } catch(Exception ex) { Log("Finalize launch failed: "+ex);Put("supervisor-error.txt",ex.ToString());failed=true; }
        }
        void Tick(object sender,EventArgs e) {
            try {
                if(!stopping && !finalizing) {
                    string stageFile=Path.Combine(control,"current-stage.txt");
                    if(File.Exists(stageFile)) {
                        string stage=File.ReadAllText(stageFile).Trim();
                        status.Text="正在执行："+(stage=="Genshin"?"原神":stage=="StarRail"?"星穹铁道":stage=="Endfield"?"终末地":stage);
                    }
                }
                if(File.Exists(Path.Combine(control,"ui-close-request.json")) && !stopping) { Close(); return; }
                if(testCloseMs>0 && elapsed.ElapsedMilliseconds>=testCloseMs && !stopping) {testCloseMs=0;Close();}
                if(stopping && !finalizing) {
                    // Give native stop and WM_CLOSE a bounded chance; the kernel then
                    // terminates every remaining descendant, without name-based killing.
                    if((stopper==null || stopper.HasExited) || (DateTime.UtcNow-closeAt).TotalSeconds>12) {
                        Snapshot(); group.Kill(); Log("Remaining job members terminated.");
                        if(group.Members().Length==0) {Put("children-closed.json","{\"allClosed\":true}");BeginFinalize();}
                    }
                } else if(!stopping && !finalizing && worker!=null && worker.HasExited) {
                    ResultCode=worker.ExitCode;failed=ResultCode!=0;
                    Log("Worker exit: "+ResultCode);BeginFinalize();
                }
                if(finalizing && !finished) {
                    if(finisher==null || finisher.HasExited || (DateTime.UtcNow-finishAt).TotalSeconds>45) {
                        if(finisher==null || !finisher.HasExited || finisher.ExitCode!=0) {failed=true;if(!stopping)ResultCode=1;Put("supervisor-error.txt","报告收尾失败或超时，请查看 finalize-receipt.json、report-error.log 与 supervisor.log。");Log("Report finalizer failed or timed out.");}
                        if(finishGroup!=null) finishGroup.Dispose();finished=true;
                        if(stopping) {allowClose=true;Close();}
                        else {status.Text=failed?"日常需要检查":"本轮日常已结束";detail.Text="点击“查看本轮记录”检查逐项结果和奖励证据。\n关闭此窗口会退出本轮仍保留的程序。";}
                    }
                }
            } catch(Exception ex) {Log(ex.ToString());group.Kill();ResultCode=1;failed=true;if(!finalizing)BeginFinalize();}
        }
        protected override void Dispose(bool disposing) {
            if(disposing) {timer.Dispose();group.Dispose();if(finishGroup!=null)finishGroup.Dispose();}
            base.Dispose(disposing);
        }
        public static int Run(string hostExe,string root,string control,string game,string resume,string config,string icon,int testCloseMs) {
            Application.EnableVisualStyles();
            using(var window=new DailyWindow(hostExe,root,control,game,resume,config,icon,testCloseMs)) {Application.Run(window);return window.ResultCode;}
        }
    }
}
