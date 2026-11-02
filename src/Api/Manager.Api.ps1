# Stable facade: all actions return the common result envelope.
function New-HyperVGpuApiResult($Operation,$Success,$Data=$null,$Message=$null) {
    [pscustomobject]@{Operation=$Operation;Success=[bool]$Success;Data=$Data;Message=$Message;TimestampUtc=[DateTime]::UtcNow.ToString('o')}
}
function Invoke-HyperVGpuApiPreflight {Invoke-HgmCommand preflight}
function Get-HyperVGpuVmSummary {
    $vms=@(Get-VM -EA Stop); $map=GetVmGpuAdapterMap $vms
    foreach ($vm in $vms) {
        $bytes=[long]0; $diskError=$null
        foreach ($disk in @(Get-HgmVmDisks $vm.Name)) {
            try {$bytes += [long](Get-VHD -Path $disk.Path -EA Stop).Size}
            catch {$diskError='Some disk capacities could not be read.'}
        }
        $adapters=if ($map.ContainsKey($vm.Name)) {@($map[$vm.Name])} else {@()}
        [pscustomobject]@{Name=$vm.Name;State="$($vm.State)";Cpu=[int]$vm.ProcessorCount
            Ram=FormatCapacityFromBytes $(if ($vm.MemoryAssigned -gt 0) {$vm.MemoryAssigned} else {$vm.MemoryStartup})
            Storage=FormatCapacityFromBytes $bytes;StorageBytes=$bytes;DiskWarning=$diskError
            Gpu=if ($adapters.Count) {GpuSummary -Adapters $adapters} else {'None'}
            Id="$($vm.Id)";Generation=$vm.Generation
            Disks=@(Get-HgmVmDisks $vm.Name | Select-Object Path,ControllerType,ControllerNumber,ControllerLocation)
            GpuAdapters=@($adapters | Select-Object AdapterId,InstancePath,MaxPartitionVRAM,MaxPartitionCompute)}
    }
}
function Get-HyperVGpuHostGpuSummary {return @(Get-HgmGpuInventory)}
function Invoke-HyperVGpuApiCreateVm([string]$Name,[int]$Cpu,[int]$RamGB,[int]$StorageGB,[string]$VhdPath,[string]$IsoPath,[switch]$EnableAutoInstall,$ImageSelection=$null,$LocalAccountConfig=$null,[switch]$OverwriteVhd) {
    $p=@{VMName=$Name;Cpu=$Cpu;RamGB=$RamGB;StorageGB=$StorageGB;VhdPath=$VhdPath;IsoPath=$IsoPath;EnableAutoInstall=[bool]$EnableAutoInstall;InstallImageIndex=$ImageSelection.Index;OverwriteVhd=[bool]$OverwriteVhd}
    if ($LocalAccountConfig) {$p.UnattendUsername=$LocalAccountConfig.Username;$p.UnattendPassword=$LocalAccountConfig.Password}
    Invoke-HgmCommand create-vm $p
}
function Invoke-HyperVGpuApiSetGpu([string]$VmName,[int]$Percent,[string]$GpuPath,[string]$GpuName) {Invoke-HgmCommand set-gpu @{VMName=$VmName;GpuPercent=$Percent;GpuPath=$GpuPath}}
function Invoke-HyperVGpuApiRemoveGpu([string]$VmName,[string]$GpuPath,[switch]$All,[switch]$CleanDrivers) {Invoke-HgmCommand remove-gpu @{VMName=$VmName;GpuPath=$GpuPath;All=[bool]$All;CleanDrivers=[bool]$CleanDrivers}}
function Invoke-HyperVGpuApiInstallDrivers([string]$VmName,[string]$GpuPath,[switch]$All,[switch]$SkipExisting) {Invoke-HgmCommand install-drivers @{VMName=$VmName;GpuPath=$GpuPath;All=[bool]$All;SkipExisting=[bool]$SkipExisting}}
function Invoke-HyperVGpuApiDeleteVm([string]$VmName,[switch]$DeleteFiles,[switch]$Force) {Invoke-HgmCommand delete-vm @{VMName=$VmName;DeleteFiles=[bool]$DeleteFiles;Force=[bool]$Force}}
function Invoke-HyperVGpuApiListVms {Invoke-HgmCommand list-vms}
function Invoke-HyperVGpuApiListGpus {Invoke-HgmCommand list-gpus}
