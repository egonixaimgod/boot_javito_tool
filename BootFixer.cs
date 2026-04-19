using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

class BootFixer
{
    class DiskInfo
    {
        public int Number;
        public string Model;
        public string Size;
        public string BootType; // "UEFI/GPT" or "Legacy/MBR"
        public bool IsGPT;
        public string WinDrive;   // e.g. "C"
        public int EFIPartNum;    // EFI partition number (0 = not found)
    }

    static void Main(string[] args)
    {
        try { Console.Title = "BootFixer"; } catch { }
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }

        // Admin check
        if (!IsAdmin())
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Process.GetCurrentProcess().MainModule.FileName;
                psi.Verb = "runas";
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch { }
            return;
        }

        try { Console.Clear(); } catch { }
        Console.WriteLine();
        Console.WriteLine("  =============================");
        Console.WriteLine("       B O O T F I X E R");
        Console.WriteLine("       Native C# v4.0");
        Console.WriteLine("  =============================");
        Console.WriteLine();

        // =============================================
        //   DISK DETECTION
        // =============================================

        Console.WriteLine("  Lemezek keresese...");
        Console.WriteLine();

        // Run diskpart list disk
        string listDiskOutput = RunDiskpart("list disk");
        if (string.IsNullOrEmpty(listDiskOutput))
        {
            Console.WriteLine("  [HIBA] Diskpart nem elerheto!");
            Console.ReadLine();
            return;
        }

        List<DiskInfo> disks = new List<DiskInfo>();

        // Parse diskpart output
        string[] lines = listDiskOutput.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string rawLine in lines)
        {
            string line = rawLine.Trim('\r', ' ');
            // Match lines like "  Disk 0    Online          931 GB      0 B         *"
            // Also handles Hungarian: "  Lemez 0    Online          931 GB      0 B         *"
            Match m = Regex.Match(line, @"^(?:Disk|Lemez)\s+(\d+)\s+\S+\s+(\d+\s+[GMTK]?B)", RegexOptions.IgnoreCase);
            if (!m.Success) continue;

            DiskInfo di = new DiskInfo();
            di.Number = int.Parse(m.Groups[1].Value);
            di.Size = m.Groups[2].Value.Trim();
            di.IsGPT = line.Contains("*");
            di.BootType = di.IsGPT ? "UEFI/GPT" : "Legacy/MBR";
            di.Model = "Lemez " + di.Number;
            di.WinDrive = null;
            di.EFIPartNum = 0;

            disks.Add(di);
        }

        if (disks.Count == 0)
        {
            Console.WriteLine("  Nem talalhato lemez!");
            Console.WriteLine();
            Console.WriteLine("  [Debug] Diskpart kimenet:");
            Console.WriteLine(listDiskOutput);
            Console.ReadLine();
            return;
        }

        // Try to get disk model names via wmic (optional, may not be available)
        try
        {
            foreach (DiskInfo di in disks)
            {
                string wmicOut = RunCmd("wmic", "diskdrive where \"Index=" + di.Number + "\" get Model /value");
                if (!string.IsNullOrEmpty(wmicOut))
                {
                    Match mm = Regex.Match(wmicOut, @"Model=(.+)", RegexOptions.IgnoreCase);
                    if (mm.Success)
                    {
                        string model = mm.Groups[1].Value.Trim('\r', '\n', ' ');
                        if (!string.IsNullOrEmpty(model))
                            di.Model = model;
                    }
                }
            }
        }
        catch { }

        // Find EFI partitions per disk
        foreach (DiskInfo di in disks)
        {
            string partOut = RunDiskpart("select disk " + di.Number + "\nlist partition");
            if (!string.IsNullOrEmpty(partOut))
            {
                string[] plines = partOut.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
                foreach (string pl in plines)
                {
                    string pline = pl.Trim('\r');
                    // Look for "System" type partition (EFI)
                    if (pline.IndexOf("System", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        pline.IndexOf("Rendszer", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        Match pm = Regex.Match(pline, @"Partition\s+(\d+)", RegexOptions.IgnoreCase);
                        if (!pm.Success)
                            pm = Regex.Match(pline, @"Part.ci.\s+(\d+)", RegexOptions.IgnoreCase);
                        if (pm.Success)
                        {
                            di.EFIPartNum = int.Parse(pm.Groups[1].Value);
                        }
                    }
                }
            }
        }

        // Find Windows installations
        for (char drive = 'C'; drive <= 'Z'; drive++)
        {
            string winPath = drive + ":\\Windows\\System32";
            bool hasWinload = false;
            try
            {
                if (Directory.Exists(winPath))
                {
                    // Check for winload.exe or winload.efi
                    hasWinload = File.Exists(drive + ":\\Windows\\System32\\winload.exe") ||
                                 File.Exists(drive + ":\\Windows\\System32\\winload.efi");
                }
            }
            catch { }

            if (!hasWinload) continue;

            // Find which physical disk this drive letter belongs to
            string volOut = RunDiskpart("list volume");
            if (string.IsNullOrEmpty(volOut)) continue;

            int volNum = -1;
            string[] vlines = volOut.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string vl in vlines)
            {
                string vline = vl.Trim('\r');
                // Match volume with this drive letter
                // Format: "  Volume 2     C   ...
                if (Regex.IsMatch(vline, @"Volume\s+\d+\s+" + drive + @"\s", RegexOptions.IgnoreCase) ||
                    Regex.IsMatch(vline, @"K.tet\s+\d+\s+" + drive + @"\s", RegexOptions.IgnoreCase))
                {
                    Match vm = Regex.Match(vline, @"(?:Volume|K.tet)\s+(\d+)", RegexOptions.IgnoreCase);
                    if (vm.Success)
                        volNum = int.Parse(vm.Groups[1].Value);
                }
            }

            if (volNum < 0) continue;

            // Detail volume to find disk number
            string detOut = RunDiskpart("select volume " + volNum + "\ndetail volume");
            if (string.IsNullOrEmpty(detOut)) continue;

            string[] dlines = detOut.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string dl in dlines)
            {
                string dline = dl.Trim('\r');
                Match dm = Regex.Match(dline, @"Disk\s+(\d+)", RegexOptions.IgnoreCase);
                if (!dm.Success)
                    dm = Regex.Match(dline, @"Lemez\s+(\d+)", RegexOptions.IgnoreCase);
                if (dm.Success)
                {
                    int diskNum = int.Parse(dm.Groups[1].Value);
                    foreach (DiskInfo di in disks)
                    {
                        if (di.Number == diskNum && di.WinDrive == null)
                        {
                            di.WinDrive = drive.ToString();
                        }
                    }
                }
            }
        }

        // =============================================
        //   DISPLAY DISKS
        // =============================================

        Console.WriteLine("  Talalt lemezek:");
        Console.WriteLine("  -------------------------------------------------------");
        for (int i = 0; i < disks.Count; i++)
        {
            DiskInfo d = disks[i];
            string winText = d.WinDrive != null ? ("Windows " + d.WinDrive + ":\\") : "Nincs Windows";
            Console.WriteLine("  [{0}] {1} | {2} | {3} | {4}", i + 1, d.Model, d.Size, d.BootType, winText);
        }
        Console.WriteLine();
        Console.WriteLine("  [0] Kilepes");
        Console.WriteLine();

        // =============================================
        //   SELECTION
        // =============================================

        Console.Write("  Melyik lemezt javitsam? [szam]: ");
        string input = Console.ReadLine();
        if (string.IsNullOrEmpty(input) || input.Trim() == "0") return;

        int choice;
        if (!int.TryParse(input.Trim(), out choice) || choice < 1 || choice > disks.Count)
        {
            Console.WriteLine("  Ervenytelen valasztas!");
            Console.ReadLine();
            return;
        }

        DiskInfo sel = disks[choice - 1];

        if (sel.WinDrive == null)
        {
            Console.WriteLine();
            Console.WriteLine("  [HIBA] Ezen a lemezen nincs Windows!");
            Console.ReadLine();
            return;
        }

        Console.WriteLine();
        Console.WriteLine("  Kivalasztva: {0} | {1} | {2}", sel.Model, sel.Size, sel.BootType);
        Console.WriteLine("  Windows: {0}:\\", sel.WinDrive);
        Console.WriteLine();
        Console.Write("  Ujrairom a bootot es single boot lesz. Folytatod? (i/n): ");
        string confirm = Console.ReadLine();
        if (string.IsNullOrEmpty(confirm) || confirm.Trim().ToLower() != "i")
        {
            Console.WriteLine("  Megszakitva.");
            Console.ReadLine();
            return;
        }

        Console.WriteLine();

        string winDir = sel.WinDrive + ":\\Windows";

        if (sel.IsGPT)
            FixUEFI(sel, winDir);
        else
            FixLegacy(sel, winDir);

        // =============================================
        //   DONE
        // =============================================

        Console.WriteLine();
        Console.WriteLine("  =============================");
        Console.WriteLine("    BOOT JAVITAS KESZ!");
        Console.WriteLine("    Inditsd ujra a gepet.");
        Console.WriteLine("  =============================");
        Console.WriteLine();
        Console.Write("  Nyomj ENTER-t a kilepeshez...");
        Console.ReadLine();
    }

    // =============================================
    //   UEFI BOOT FIX
    // =============================================
    static void FixUEFI(DiskInfo disk, string winDir)
    {
        Console.WriteLine("  [1/4] EFI particio mountolasa...");

        int efiPart = disk.EFIPartNum;
        if (efiPart == 0)
        {
            // Try to find it again
            string partOut = RunDiskpart("select disk " + disk.Number + "\nlist partition");
            if (!string.IsNullOrEmpty(partOut))
            {
                string[] plines = partOut.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
                foreach (string pl in plines)
                {
                    string pline = pl.Trim('\r');
                    if (pline.IndexOf("System", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        pline.IndexOf("Rendszer", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        Match pm = Regex.Match(pline, @"(?:Partition|Part.ci.)\s+(\d+)", RegexOptions.IgnoreCase);
                        if (pm.Success)
                            efiPart = int.Parse(pm.Groups[1].Value);
                    }
                }
            }
        }

        if (efiPart == 0)
        {
            Console.WriteLine("  [HIBA] Nem talalhato EFI particio!");
            Console.ReadLine();
            return;
        }

        // Find free drive letter
        char efiLetter = FindFreeLetter();
        if (efiLetter == ' ')
        {
            Console.WriteLine("  [HIBA] Nincs szabad betujel!");
            Console.ReadLine();
            return;
        }

        // Mount EFI
        RunDiskpart("select disk " + disk.Number + "\nselect partition " + efiPart + "\nassign letter=" + efiLetter);
        Thread.Sleep(1500);

        if (!Directory.Exists(efiLetter + ":\\"))
        {
            Console.WriteLine("  [HIBA] EFI mount sikertelen!");
            Console.ReadLine();
            return;
        }
        Console.WriteLine("  [OK] EFI mountolva: {0}:\\", efiLetter);

        // Delete old boot files and rewrite
        Console.WriteLine("  [2/4] Boot fajlok ujrairasa...");
        string efiBoot = efiLetter + ":\\EFI\\Microsoft\\Boot";
        try
        {
            if (Directory.Exists(efiBoot))
                Directory.Delete(efiBoot, true);
        }
        catch { }

        int rc = RunExe("bcdboot", "\"" + winDir + "\" /s " + efiLetter + ": /f UEFI /l hu-HU");
        if (rc != 0)
            rc = RunExe("bcdboot", "\"" + winDir + "\" /s " + efiLetter + ": /f UEFI");
        if (rc == 0)
            Console.WriteLine("  [OK] BCDBoot UEFI sikeres!");
        else
            Console.WriteLine("  [!] BCDBoot figyelmeztetes - ellenorizd");

        // Single boot
        Console.WriteLine("  [3/4] Single boot beallitas...");
        string bcdStore = efiLetter + ":\\EFI\\Microsoft\\Boot\\BCD";
        if (File.Exists(bcdStore))
        {
            SetSingleBoot(bcdStore);
            Console.WriteLine("  [OK] Single boot beallitva!");
        }
        else
        {
            Console.WriteLine("  [!] BCD store nem talalhato");
        }

        // Unmount EFI
        Console.WriteLine("  [4/4] EFI levalasztasa...");
        RunDiskpart("select disk " + disk.Number + "\nselect partition " + efiPart + "\nremove letter=" + efiLetter);
        Console.WriteLine("  [OK] Kesz!");
    }

    // =============================================
    //   LEGACY BOOT FIX
    // =============================================
    static void FixLegacy(DiskInfo disk, string winDir)
    {
        // Active partition
        Console.WriteLine("  [1/4] Aktiv particio beallitasa...");

        string partOut = RunDiskpart("select disk " + disk.Number + "\nlist partition");
        int firstPart = 0;
        bool hasActive = false;

        if (!string.IsNullOrEmpty(partOut))
        {
            string[] plines = partOut.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string pl in plines)
            {
                string pline = pl.Trim('\r');
                Match pm = Regex.Match(pline, @"(?:Partition|Part.ci.)\s+(\d+)", RegexOptions.IgnoreCase);
                if (pm.Success)
                {
                    int pn = int.Parse(pm.Groups[1].Value);
                    if (firstPart == 0) firstPart = pn;
                    if (pline.Contains("*")) hasActive = true;
                }
            }
        }

        if (hasActive)
        {
            Console.WriteLine("  [OK] Aktiv particio rendben.");
        }
        else if (firstPart > 0)
        {
            RunDiskpart("select disk " + disk.Number + "\nselect partition " + firstPart + "\nactive");
            Console.WriteLine("  [OK] Particio {0} aktivva teve!", firstPart);
        }

        // MBR + boot sector
        Console.WriteLine("  [2/4] MBR es boot szektor ujrairasa...");
        RunExe("bootrec", "/fixmbr");
        RunExe("bootrec", "/fixboot");
        RunExe("bootrec", "/rebuildbcd");
        Console.WriteLine("  [OK] MBR/bootszektor ujrairva!");

        // BCDBoot
        Console.WriteLine("  [3/4] BCDBoot futtatasa...");

        int activePart = firstPart;
        if (activePart == 0) activePart = 1;

        char tmpLetter = FindFreeLetter();
        bool mounted = false;

        if (tmpLetter != ' ')
        {
            RunDiskpart("select disk " + disk.Number + "\nselect partition " + activePart + "\nassign letter=" + tmpLetter);
            Thread.Sleep(1000);
            if (Directory.Exists(tmpLetter + ":\\"))
                mounted = true;
        }

        if (mounted)
        {
            int rc = RunExe("bcdboot", "\"" + winDir + "\" /s " + tmpLetter + ": /f BIOS /l hu-HU");
            if (rc != 0)
                rc = RunExe("bcdboot", "\"" + winDir + "\" /s " + tmpLetter + ": /f BIOS");
            if (rc == 0)
                Console.WriteLine("  [OK] BCDBoot BIOS sikeres!");
            else
                Console.WriteLine("  [!] BCDBoot figyelmeztetes");

            RunDiskpart("select disk " + disk.Number + "\nselect partition " + activePart + "\nremove letter=" + tmpLetter);
        }
        else
        {
            RunExe("bcdboot", "\"" + winDir + "\" /f BIOS");
            Console.WriteLine("  [OK] BCDBoot fallback.");
        }

        // Single boot
        Console.WriteLine("  [4/4] Single boot beallitas...");
        SetSingleBoot(null); // null = system BCD
        Console.WriteLine("  [OK] Single boot beallitva!");
    }

    // =============================================
    //   HELPER: Set Single Boot
    // =============================================
    static void SetSingleBoot(string storePath)
    {
        string storeArg = storePath != null ? "/store \"" + storePath + "\"" : "";

        // Get all OS entries
        string enumOut = RunCmdOutput("bcdedit", storeArg + " /enum osloader");
        if (string.IsNullOrEmpty(enumOut)) return;

        // Get default entry
        string mgrOut = RunCmdOutput("bcdedit", storeArg + " /enum {bootmgr}");
        string defaultId = null;
        if (!string.IsNullOrEmpty(mgrOut))
        {
            Match dm = Regex.Match(mgrOut, @"default\s+(\{[^}]+\})");
            if (dm.Success)
                defaultId = dm.Groups[1].Value;
        }

        // Find all identifiers
        MatchCollection matches = Regex.Matches(enumOut, @"identifier\s+(\{[^}]+\})");
        foreach (Match m in matches)
        {
            string id = m.Groups[1].Value;
            if (id != "{default}" && id != defaultId)
            {
                RunExe("bcdedit", storeArg + " /delete " + id + " /cleanup");
            }
        }

        // Set timeout to 0
        RunExe("bcdedit", storeArg + " /timeout 0");
    }

    // =============================================
    //   HELPER: Run diskpart with script
    // =============================================
    static string RunDiskpart(string commands)
    {
        string tmpDir = Environment.GetEnvironmentVariable("TEMP");
        if (string.IsNullOrEmpty(tmpDir) || !Directory.Exists(tmpDir))
        {
            tmpDir = "X:\\Windows\\Temp";
            if (!Directory.Exists(tmpDir))
                tmpDir = Environment.GetFolderPath(Environment.SpecialFolder.System);
        }

        string scriptPath = Path.Combine(tmpDir, "bf_dp_" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".txt");
        try
        {
            File.WriteAllText(scriptPath, commands, Encoding.ASCII);
            string output = RunCmdOutput("diskpart", "/s \"" + scriptPath + "\"");
            return output;
        }
        catch (Exception ex)
        {
            return "ERROR: " + ex.Message;
        }
        finally
        {
            try { File.Delete(scriptPath); } catch { }
        }
    }

    // =============================================
    //   HELPER: Run external command
    // =============================================
    static int RunExe(string exe, string arguments)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = exe;
            psi.Arguments = arguments;
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            Process p = Process.Start(psi);
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit(30000);
            return p.ExitCode;
        }
        catch
        {
            return -1;
        }
    }

    static string RunCmdOutput(string exe, string arguments)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = exe;
            psi.Arguments = arguments;
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            Process p = Process.Start(psi);
            string output = p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit(30000);
            return output;
        }
        catch
        {
            return null;
        }
    }

    static string RunCmd(string exe, string arguments)
    {
        return RunCmdOutput(exe, arguments);
    }

    // =============================================
    //   HELPER: Find free drive letter
    // =============================================
    static char FindFreeLetter()
    {
        char[] letters = { 'Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q' };
        foreach (char l in letters)
        {
            if (!Directory.Exists(l + ":\\"))
                return l;
        }
        return ' ';
    }

    // =============================================
    //   HELPER: Admin check
    // =============================================
    static bool IsAdmin()
    {
        try
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }
}
