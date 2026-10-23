# Copy this file to config.local.ps1 (git-ignored) and fill in your values.
# All host scripts dot-source config.local.ps1 from the repository root.

$Cfg = @{
    # VMware
    VmRun        = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'
    Vmx          = 'C:\VMs\Win11Test\Win11Test.vmx'       # your VM
    VmPassword   = ''                                      # only for encrypted VMs (vmrun -vp); leave '' otherwise
    GuestUser    = 'testuser'                              # local admin account in the guest
    GuestPass    = 'change-me'

    # KDNET (values from scripts/guest/setup_kdnet.ps1 output)
    HostIp       = '192.168.150.1'                         # host IP on VMnet1 (host-only)
    Port         = 50000
    Key          = 'w.x.y.z'                               # KDNET key printed in the guest — keep private
    BusParams    = '27.0.0'                                # guest debug NIC (from kdnet.exe)
    KDebugGuid   = '{00000000-0000-0000-0000-000000000000}' # GUID of the "Win11 KDebug" boot entry

    # Debugger
    Kd           = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\kd.exe'
    SymbolPath   = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols'

    # Where logs/sessions are written (git-ignored)
    LogDir       = (Join-Path $PSScriptRoot 'logs')
    GuestWorkDir = 'C:\KDNET'
}
