function Start-HgmDesktop {
    param([string]$ProjectRoot)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $reader=New-Object Xml.XmlNodeReader ([xml](Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\Desktop\Window.xaml') -Raw))
    $script:HgmWindow=[Windows.Markup.XamlReader]::Load($reader)
    $script:HgmControls=@{}
    foreach ($match in [regex]::Matches([IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\Desktop\Window.xaml')),'Name="([A-Za-z]+)"')) {$script:HgmControls[$match.Groups[1].Value]=$script:HgmWindow.FindName($match.Groups[1].Value)}
    $script:HgmUi=[pscustomobject]@{Root=$ProjectRoot;Worker=$null;Handle=$null;Token=$null;Queue=$null;Command=$null;LastResult=$null;RefreshQueue=(New-Object 'System.Collections.Generic.Queue[string]');Target=$null;CloseWhenDone=$false}
    $script:HgmRunspace=[RunspaceFactory]::CreateRunspace();$script:HgmRunspace.ApartmentState='STA';$script:HgmRunspace.ThreadOptions='ReuseThread';$script:HgmRunspace.Open()
    $script:HgmTimer=New-Object Windows.Threading.DispatcherTimer
    $script:HgmTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $script:HgmTimer.Add_Tick({Update-HgmDesktopWorker})
    $c=$script:HgmControls
    $c.Refresh.Add_Click({Start-HgmDesktopRefresh})
    $c.OpenLogs.Add_Click({$path=Join-Path $env:LOCALAPPDATA 'HyperV-Gpu-Manager\Logs';if (Test-Path -LiteralPath $path) {Start-Process explorer.exe -ArgumentList ('"'+$path+'"')} else {Add-HgmDesktopActivity 'No log files have been written yet.'}})
    $c.Cancel.Add_Click({if ($script:HgmUi.Token) {$script:HgmUi.Token.Cancel();$script:HgmControls.Status.Text='Cancellation requested. Waiting for a safe boundary...'}})
    $c.Vms.Add_SelectionChanged({Set-HgmDesktopTarget})
    $c.Preset.Add_SelectionChanged({Set-HgmDesktopPreset})
    $c.Profiles.Add_SelectionChanged({Set-HgmDesktopProfile})
    $c.BrowseIso.Add_Click({$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='ISO images (*.iso)|*.iso';if ($dialog.ShowDialog()) {$script:HgmControls.IsoPath.Text=$dialog.FileName}})
    $c.ScanIso.Add_Click({Start-HgmDesktopOperation 'list-images' @{IsoPath=$script:HgmControls.IsoPath.Text}})
    $c.CreateVm.Add_Click({Invoke-HgmDesktopFormCommand 'create-vm'})
    $c.SaveProfile.Add_Click({Invoke-HgmDesktopFormCommand 'save-profile'})
    $c.DeleteProfile.Add_Click({$p=$script:HgmControls.Profiles.SelectedItem;if ($p -and (Confirm-HgmDesktop "Delete saved profile '$($p.Name)'?")) {Start-HgmDesktopOperation 'delete-profile' @{ProfileName=$p.Name}}})
    $c.MakeDefault.Add_Click({$p=$script:HgmControls.Profiles.SelectedItem;if ($p) {Start-HgmDesktopOperation 'default-profile' @{ProfileName=$p.Name}}})
    $c.BackupConfig.Add_Click({$dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='JSON configuration (*.json)|*.json';$dialog.FileName='gpu-manager-profiles.json';if ($dialog.ShowDialog()) {Start-HgmDesktopOperation 'backup-config' @{ConfigurationPath=$dialog.FileName}}})
    $c.RestoreConfig.Add_Click({$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='JSON configuration (*.json)|*.json';if ($dialog.ShowDialog() -and (Confirm-HgmDesktop 'Replace the saved profiles from this backup? Passwords require the same Windows user and machine.')) {Start-HgmDesktopOperation 'restore-config' @{ConfigurationPath=$dialog.FileName}}})
    $c.ExportResult.Add_Click({if ($script:HgmUi.LastResult) {$dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='JSON result (*.json)|*.json';$dialog.FileName='gpu-manager-result.json';if ($dialog.ShowDialog()) {[IO.File]::WriteAllText($dialog.FileName,($script:HgmUi.LastResult | ConvertTo-Json -Depth 30))}}})
    foreach ($pair in @(@('AssignGpu','set-gpu'),@('PlanDrivers','plan-drivers'),@('InstallDrivers','install-drivers'),@('AuditDrivers','audit-drivers'),@('RecoverDrivers','recover-drivers'),@('RemoveGpu','remove-gpu'),@('DeleteVm','delete-vm'))) {
        $c[$pair[0]].Tag=$pair[1]
        $c[$pair[0]].Add_Click({param($sender,$event) Invoke-HgmDesktopTargetCommand $sender.Tag})
    }
    $script:HgmWindow.Add_Closing({param($sender,$event) if ($script:HgmUi.Worker) {$event.Cancel=$true;$script:HgmUi.CloseWhenDone=$true;$script:HgmUi.Token.Cancel();$script:HgmControls.Status.Text='Waiting for safe cancellation before closing...'}})
    $script:HgmWindow.Add_ContentRendered({Start-HgmDesktopRefresh})
    try {$null=$script:HgmWindow.ShowDialog()}
    finally {$script:HgmTimer.Stop();if ($script:HgmUi.Worker) {$script:HgmUi.Worker.Dispose()};$script:HgmRunspace.Dispose()}
}

function Add-HgmDesktopActivity([string]$Text) {
    $box=$script:HgmControls.Activity
    if ($box.Text.Length -gt 150000) {$box.Text=$box.Text.Substring($box.Text.Length-100000)}
    $box.AppendText(([DateTime]::Now.ToString('HH:mm:ss')+'  '+$Text+[Environment]::NewLine));$box.ScrollToEnd()
}
function Confirm-HgmDesktop([string]$Text) {return [Windows.MessageBox]::Show($script:HgmWindow,$Text,'Review operation','YesNo','Warning') -eq 'Yes'}
function Start-HgmDesktopOperation([string]$Command,[hashtable]$Parameters) {
    if ($script:HgmUi.Worker) {Add-HgmDesktopActivity 'Wait for the current operation or cancel it safely.';return}
    $script:HgmUi.Command=$Command
    $script:HgmUi.Queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:HgmUi.Token=New-Object Threading.CancellationTokenSource
    $worker=[PowerShell]::Create();$worker.Runspace=$script:HgmRunspace
    $null=$worker.AddScript({param($root,$command,$parameters,$queue,$token)
        $ErrorActionPreference='Stop';$InformationPreference='SilentlyContinue';$ProgressPreference='SilentlyContinue'
        Import-Module (Join-Path $root 'src\HyperVGpuManager.psd1') -Force -DisableNameChecking
        Invoke-HgmCommand -Command $command -Parameters $parameters -ProgressQueue $queue -Cancellation $token
    }).AddArgument($script:HgmUi.Root).AddArgument($Command).AddArgument($Parameters).AddArgument($script:HgmUi.Queue).AddArgument($script:HgmUi.Token)
    $script:HgmUi.Worker=$worker;$script:HgmUi.Handle=$worker.BeginInvoke()
    $script:HgmControls.Cancel.IsEnabled=$true;$script:HgmControls.Status.Text="Working: $Command..."
    $script:HgmTimer.Start()
}
function Start-HgmDesktopRefresh {
    if ($script:HgmUi.Worker) {return}
    $script:HgmUi.RefreshQueue.Clear()
    foreach ($cmd in @('list-vms','list-gpus','list-profiles')) {$script:HgmUi.RefreshQueue.Enqueue($cmd)}
    Start-HgmDesktopOperation 'preflight' @{}
}
function Update-HgmDesktopWorker {
    $state=$script:HgmUi;if (!$state.Worker) {return}
    $item=$null
    while ($state.Queue.TryDequeue([ref]$item)) {Add-HgmDesktopActivity "$($item.Level): $($item.Message)"}
    if (!$state.Handle.IsCompleted) {return}
    try {
        $results=@($state.Worker.EndInvoke($state.Handle));$result=$results | Select-Object -Last 1
        if (!$result -or $state.Worker.HadErrors) {throw 'The background operation failed. Check host prerequisites and the diagnostic log.'}
        $state.LastResult=$result
        $script:HgmControls.Status.Text=$result.Message
        if (!$result.Success) {Add-HgmDesktopActivity $result.Message}
        switch ($state.Command) {
            'preflight' {if ($result.Data) {$script:HgmControls.Checks.ItemsSource=@($result.Data.Checks);$script:HgmControls.HostSummary.Text="$($result.Data.OperatingSystem) / build $($result.Data.Build) / $($result.Data.Support)"}}
            'list-vms' {$script:HgmControls.Vms.ItemsSource=@($result.Data | Where-Object {$null -ne $_});$state.Target=$null;Set-HgmDesktopTarget}
            'list-gpus' {$script:HgmControls.Devices.ItemsSource=@($result.Data | Where-Object {$null -ne $_});$script:HgmControls.HostGpu.ItemsSource=@($result.Data | Where-Object Partitionable);$script:HgmControls.HostGpu.SelectedIndex=0}
            'list-profiles' {$script:HgmControls.Profiles.ItemsSource=@($result.Data | Where-Object {$null -ne $_})}
            'list-images' {$script:HgmControls.ImageOptions.Text=(@($result.Data | ForEach-Object {"$($_.Index): $($_.Name)"}) -join ' | ')}
            default {
                if ($result.Data) {Add-HgmDesktopActivity ($result.Data | ConvertTo-Json -Depth 12)}
                if ($result.Success -and $state.Command -in @('create-vm','delete-vm','set-gpu','remove-gpu','save-profile','delete-profile','default-profile','restore-config')) {
                    $state.RefreshQueue.Enqueue('list-vms');$state.RefreshQueue.Enqueue('list-profiles')
                }
            }
        }
    } catch {$script:HgmControls.Status.Text=$_.Exception.Message;Add-HgmDesktopActivity $_.Exception.Message}
    finally {$state.Worker.Dispose();$state.Worker=$null;$state.Token.Dispose();$state.Token=$null;$script:HgmControls.Cancel.IsEnabled=$false;$script:HgmTimer.Stop()}
    if ($state.CloseWhenDone) {$state.RefreshQueue.Clear();$script:HgmWindow.Close();return}
    if ($state.RefreshQueue.Count) {Start-HgmDesktopOperation $state.RefreshQueue.Dequeue() @{}}
}
function Set-HgmDesktopTarget {
    $c=$script:HgmControls;$vm=$c.Vms.SelectedItem;$script:HgmUi.Target=$vm
    $c.TargetLabel.Text=if ($vm) {"Target: $($vm.Name) / $($vm.State). Offline operations require the Off state."} else {'Select a target in the Virtual machines tab.'}
    $c.AssignedGpu.ItemsSource=@([pscustomobject]@{Label='All assigned GPUs';Path=$null})+@($vm.GpuAdapters | ForEach-Object {if ($_) {[pscustomobject]@{Label=$_.InstancePath;Path=$_.InstancePath}}})
    $c.AssignedGpu.SelectedIndex=0
    $c.SystemDisk.ItemsSource=@([pscustomobject]@{Label='Automatically find a single Windows installation';Path=$null})+@($vm.Disks | ForEach-Object {if ($_) {[pscustomobject]@{Label=$_.Path;Path=$_.Path}}})
    $c.SystemDisk.SelectedIndex=0
}
function Set-HgmDesktopPreset {
    $c=$script:HgmControls
    switch ($c.Preset.SelectedIndex) {
        0 {$c.VmName.Text='Dev-VM';$c.Cpu.Text='4';$c.Ram.Text='8';$c.Storage.Text='128'}
        1 {$c.VmName.Text='Gaming-VM';$c.Cpu.Text='8';$c.Ram.Text='16';$c.Storage.Text='256'}
        2 {$c.VmName.Text='ML-VM';$c.Cpu.Text='12';$c.Ram.Text='32';$c.Storage.Text='512'}
    }
    $c.Profiles.SelectedIndex=-1;$c.Password.Clear()
}
function Set-HgmDesktopProfile {
    $c=$script:HgmControls;$p=$c.Profiles.SelectedItem;if (!$p) {return}
    $c.VmName.Text=$p.VmName;$c.Cpu.Text=$p.Cpu;$c.Ram.Text=$p.RamGB;$c.Storage.Text=$p.StorageGB
    $c.VhdDirectory.Text=$p.VhdPath;$c.IsoPath.Text=$p.IsoPath;$c.AutoInstall.IsChecked=$p.EnableAutoInstall
    $c.ImageIndex.Text=$p.InstallImageIndex;$c.Username.Text=$p.UnattendUsername;$c.Password.Clear()
    $c.ProfileName.Text=$p.Name;$c.DefaultProfile.IsChecked=$p.IsDefault;$c.OverwriteVhd.IsChecked=$p.OverwriteVhd
}
function Invoke-HgmDesktopFormCommand([string]$Command) {
    $c=$script:HgmControls
    try {
        $p=@{VMName=$c.VmName.Text;Preset='custom';Cpu=[int]$c.Cpu.Text;RamGB=[int]$c.Ram.Text;StorageGB=[int]$c.Storage.Text;VhdPath=$c.VhdDirectory.Text;IsoPath=$c.IsoPath.Text
            EnableAutoInstall=[bool]$c.AutoInstall.IsChecked;InstallImageIndex=[int]$c.ImageIndex.Text;UnattendUsername=$c.Username.Text
            OverwriteVhd=[bool]$c.OverwriteVhd.IsChecked;ProfileName=$c.ProfileName.Text;SetDefault=[bool]$c.DefaultProfile.IsChecked}
        if ($c.Password.Password) {$p.UnattendPassword=$c.Password.Password}
        if ($Command -eq 'create-vm') {
            if (!$c.Profiles.SelectedItem) {[void]$p.Remove('ProfileName')}
            elseif (!$p.ProfileName) {$p.ProfileName=$c.Profiles.SelectedItem.Name}
            if (!(Confirm-HgmDesktop "Create VM '$($p.VMName)' with $($p.Cpu) vCPU, $($p.RamGB) GiB RAM and $($p.StorageGB) GiB disk?")) {return}
        }
        Start-HgmDesktopOperation $Command $p
        $c.Password.Clear()
    } catch {Add-HgmDesktopActivity 'Enter whole numbers for CPU, memory, disk size and installation index.'}
}
function Invoke-HgmDesktopTargetCommand([string]$Command) {
    $c=$script:HgmControls;$vm=$script:HgmUi.Target
    if (!$vm) {Add-HgmDesktopActivity 'Select a VM in the Virtual machines tab first.';return}
    $p=@{VMName=$vm.Name;Shutdown=[bool]$c.Shutdown.IsChecked;GpuPath=$c.AssignedGpu.SelectedItem.Path;SystemDiskPath=$c.SystemDisk.SelectedItem.Path;SkipExisting=[bool]$c.SkipExisting.IsChecked;CleanDrivers=[bool]$c.CleanDrivers.IsChecked}
    if ($Command -eq 'set-gpu') {
        $gpu=$c.HostGpu.SelectedItem
        if (!$gpu) {Add-HgmDesktopActivity 'Select a partitionable host GPU first.';return}
        $percent=0
        if (![int]::TryParse($c.Percent.Text,[ref]$percent) -or $percent -lt 1 -or $percent -gt 100) {Add-HgmDesktopActivity 'Enter a GPU allocation from 1 to 100.';return}
        $p.GpuPath=$gpu.InstancePath;$p.GpuPercent=$percent
    }
    if ($Command -in @('delete-vm','remove-gpu')) {
        $p.DeleteFiles=[bool]$c.DeleteFiles.IsChecked;$p.Force=$true
        $detail=if ($Command -eq 'delete-vm' -and $p.DeleteFiles) {' Associated disk files and the generated ISO will also be deleted.'} else {' Review the selected target and cleanup options before continuing.'}
        if (!(Confirm-HgmDesktop "$Command on '$($vm.Name)'?$detail")) {return}
    }
    Start-HgmDesktopOperation $Command $p
}
