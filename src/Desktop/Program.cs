using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Windows;

// Small native desktop host for the inbox Windows PowerShell runtime. No shell
// window, command-line credentials, web server, or downloaded runtime required.
internal static class Program
{
    [STAThread]
    private static int Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript(@"param($root)
                        $ErrorActionPreference = 'Stop'
                        Import-Module (Join-Path $root 'src\HyperVGpuManager.psd1') -DisableNameChecking
                        . (Join-Path $root 'src\Desktop\Window.ps1')
                        Start-HgmDesktop -ProjectRoot $root").AddArgument(root);
                    ps.Invoke();
                    if (ps.HadErrors)
                    {
                        MessageBox.Show(ps.Streams.Error[0].Exception.Message,
                            "Hyper-V GPU Manager startup failed", MessageBoxButton.OK, MessageBoxImage.Error);
                        return 1;
                    }
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Hyper-V GPU Manager", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }
}
