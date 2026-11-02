@{
    RootModule='HyperVGpuManager.psm1'
    ModuleVersion='2.0.0'
    GUID='3789f0d8-c135-4a03-bd30-ec9fc58adc44'
    Author='Daniel Chrobak'
    Copyright='Copyright (c) 2025 Daniel Chrobak. MIT License.'
    Description='Native Hyper-V GPU partition management with verified offline driver transactions.'
    PowerShellVersion='5.1'
    FunctionsToExport=@('Invoke-HgmCommand','Start-HyperVGpuInteractiveMenu','Invoke-HyperVGpuCliCommand','Invoke-HyperVGpuApi*','Get-HyperVGpuVmSummary','Get-HyperVGpuHostGpuSummary')
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
    PrivateData=@{PSData=@{Tags=@('Hyper-V','GPU','Windows');LicenseUri='https://github.com/DanielChrobak/Hyper-V-GPU-Paravirtualization-Manager/blob/main/LICENSE';ProjectUri='https://github.com/DanielChrobak/Hyper-V-GPU-Paravirtualization-Manager'}}
}
