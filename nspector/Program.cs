using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using nspector.Common;
using nspector.Common.Helper;
using nspector.Native.WINAPI;

namespace nspector
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                SafeNativeMethods.DeleteFile(Application.ExecutablePath + ":Zone.Identifier");
            }
            catch { }

            // === CLI MODE ===
            if (args.Length > 0 && (args[0].StartsWith("-") || args[0].StartsWith("--")))
            {
                RunCliMode(args);
                return;
            }

            // === GUI MODE (original) ===
#if RELEASE
            try
            {
#endif
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            DropDownMenuScrollWheelHandler.Enable(true);

            var argFileIndex = ArgFileIndex(args);
            if (argFileIndex != -1)
            {
                if (new FileInfo(args[argFileIndex]).Extension.ToLowerInvariant() == ".nip")
                {
                    try
                    {
                        var import = DrsServiceLocator.ImportService;
                        var importReport = import.ImportProfiles(args[argFileIndex]);
                        GC.Collect();
                        SendImportMessageToExistingInstance();
                        if (string.IsNullOrEmpty(importReport) && !ArgExists(args, "-silentImport") && !ArgExists(args, "-silent"))
                        {
                            frmDrvSettings.ShowImportDoneMessage(importReport);
                        }
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show("Import Error: " + ex.Message, Application.ProductName + " Error",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            else if (ArgExists(args, "-createCSN"))
            {
                File.WriteAllText("CustomSettingNames.xml", Properties.Resources.CustomSettingNames);
            }
            else
            {
                bool createdNew = true;
                using (Mutex mutex = new Mutex(true, Application.ProductName, out createdNew))
                {
                    if (createdNew)
                    {
                        Application.Run(new frmDrvSettings(ArgExists(args, "-showOnlyCSN"), ArgExists(args, "-disableScan")));
                    }
                    else
                    {
                        BringExistingInstanceToFront();
                    }
                }
            }
#if RELEASE
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message + "\r\n\r\n" + ex.StackTrace, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
#endif
        }

        // =====================================
        // CLI MODE
        // =====================================
        static void RunCliMode(string[] args)
        {
            // === PERFIL REQUERIDO ===
            string profileName = GetArgValue(args, "--profile", "-p");
            if (string.IsNullOrEmpty(profileName))
            {
                Console.WriteLine("Error: --profile <name> is required.");
                return;
            }

            try
            {
                var service = DrsServiceLocator.SettingService;
                if (service == null)
                {
                    Console.WriteLine("Error: Service not initialized.");
                    return;
                }

                // === --list-settings | findstr ID ===
                if (ArgExists(args, "--list-settings"))
                {
                    var apps = new Dictionary<string, string>();
                    var settings = service.GetSettingsForProfile(profileName, SettingViewMode.IncludeScannedSetttings, ref apps);

                    foreach (var s in settings.Where(x => !x.IsSettingHidden).OrderBy(x => x.SettingId))
                    {
                        string name = s.SettingText ?? "Unknown";
                        string value = s.ValueText ?? "0x0";
                        string raw = s.ValueRaw ?? "0x0";
                        Console.WriteLine($"{s.SettingId:X8} {name} {value} {raw}");
                    }
                    return;
                }

                // === --set 0xID=0xVAL ===
                if (ArgExists(args, "--set"))
                {
                    var parts = GetArgValue(args, "--set").Split('=');
                    if (parts.Length != 2 ||
                        !uint.TryParse(parts[0].TrimStart('0', 'x', 'X'), System.Globalization.NumberStyles.HexNumber, null, out var settingId) ||
                        !uint.TryParse(parts[1].TrimStart('0', 'x', 'X'), System.Globalization.NumberStyles.HexNumber, null, out var value))
                    {
                        Console.WriteLine("Error: --set 0x12345678=0x1");
                        return;
                    }
                    service.SetDwordValueToProfile(profileName, settingId, value);
                    Console.WriteLine($"Set 0x{settingId:X8} = 0x{value:X8}");
                    return;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("CLI Error: " + ex.Message);
            }
        }

        static string Truncate(string s, int len) => s?.Length > len ? s.Substring(0, len - 3) + "..." : s ?? "";

        static string GetArgValue(string[] args, params string[] flags)
        {
            for (int i = 0; i < args.Length; i++)
            {
                foreach (var f in flags)
                    if (args[i].Equals(f, StringComparison.OrdinalIgnoreCase))
                        return i + 1 < args.Length ? args[i + 1] : "";
            }
            return "";
        }

        static bool ArgExists(string[] args, string arg)
        {
            return args.Any(a => a.Equals(arg, StringComparison.OrdinalIgnoreCase));
        }

        static int ArgFileIndex(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
                if (File.Exists(args[i]))
                    return i;
            return -1;
        }

        static void SendImportMessageToExistingInstance()
        {
            Process current = Process.GetCurrentProcess();
            foreach (Process process in Process.GetProcessesByName(current.ProcessName.Replace(".vshost", "")))
            {
                if (process.Id != current.Id && process.MainWindowTitle.Contains("Settings"))
                {
                    MessageHelper mh = new MessageHelper();
                    mh.sendWindowsStringMessage((int)process.MainWindowHandle, 0, "ProfilesImported");
                }
            }
        }

        static void BringExistingInstanceToFront()
        {
            Process current = Process.GetCurrentProcess();
            foreach (Process process in Process.GetProcessesByName(current.ProcessName.Replace(".vshost", "")))
            {
                if (process.Id != current.Id && process.MainWindowTitle.Contains("Settings"))
                {
                    MessageHelper mh = new MessageHelper();
                    mh.bringAppToFront((int)process.MainWindowHandle);
                }
            }
        }
    }
}