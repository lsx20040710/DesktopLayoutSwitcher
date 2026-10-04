using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("DesktopLayoutSwitcher")]
[assembly: AssemblyDescription("Windows desktop layout launcher")]
[assembly: AssemblyVersion("__APP_VERSION__.0")]
[assembly: AssemblyFileVersion("__APP_VERSION__.0")]

internal static class Launcher
{
    private const string AppName = "DesktopLayoutSwitcher";

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        try
        {
            if (!Environment.Is64BitOperatingSystem || !Environment.Is64BitProcess)
                throw new PlatformNotSupportedException("This release requires 64-bit Windows 10 or Windows 11.");

            string directory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(directory, "DesktopLayoutSwitcher.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("DesktopLayoutSwitcher.ps1 is missing. Reinstall or extract the complete portable ZIP.", script);

            // An x64 launcher resolves System32 to the x64 Windows PowerShell 5.1 host.
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                throw new FileNotFoundException("Windows PowerShell 5.1 is not available.", powershell);

            var command = new StringBuilder("-STA -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
            command.Append(QuoteArgument(script));
            foreach (string argument in args)
                command.Append(' ').Append(QuoteArgument(argument));

            var output = new StringBuilder();
            var outputLock = new object();
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = command.ToString(),
                    WorkingDirectory = directory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardError = true,
                    RedirectStandardOutput = true
                };
                DataReceivedEventHandler record = delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data == null) return;
                    lock (outputLock)
                    {
                        output.AppendLine(e.Data);
                        if (output.Length > 32768) output.Remove(0, output.Length - 32768);
                    }
                };
                process.ErrorDataReceived += record;
                process.OutputDataReceived += record;
                process.Start();
                process.BeginErrorReadLine();
                process.BeginOutputReadLine();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    string details;
                    lock (outputLock) details = output.ToString().Trim();
                    ShowFailure("Windows PowerShell exited with code " + process.ExitCode + ".\r\n\r\n" + details);
                }
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            ShowFailure(error.Message);
            return 1;
        }
    }

    // Quote each argument using Windows command-line escaping; never use -Command.
    private static string QuoteArgument(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                slashes++;
                continue;
            }
            if (character == '"')
                result.Append('\\', slashes * 2 + 1).Append('"');
            else
                result.Append('\\', slashes).Append(character);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    private static void ShowFailure(string details)
    {
        string message = details;
        try
        {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName, "logs");
            Directory.CreateDirectory(directory);
            string log = Path.Combine(directory, "launcher-error.log");
            File.WriteAllText(log, DateTime.Now.ToString("s") + Environment.NewLine + details, Encoding.UTF8);
            message += "\r\n\r\nError log: " + log;
        }
        catch { /* The error dialog remains available when a log cannot be written. */ }
        if (message.Length > 5000) message = message.Substring(0, 5000) + "\r\n[truncated]";
        MessageBox.Show(message, AppName + " - startup failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
