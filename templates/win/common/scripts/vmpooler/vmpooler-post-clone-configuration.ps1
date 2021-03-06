# This script is run immediately post-clone to configure the machine as a clone of the template.
#
. C:\Packer\Scripts\windows-env.ps1

$ErrorActionPreference = "Stop"

# Used Frequently throughout
$CygwinDir = "$ENV:CYGWINDIR"

# One off registry fix for background which isn't copied correctly from Default User profile
reg.exe ADD "HKCU\Control Panel\Colors" /v "Background" /t REG_SZ /d "10 59 118" /f

# First things first - resync time to make sure we aren't using ESX/VMware time (RE-8033)

If ($WindowsVersion -like $WindowsServer2008) {
  Write-Output "Resync Time not done for Win-2008"
}
else {
  Write-Output "Resyncing Time"
  net start w32time
  w32tm /resync
  w32tm /tz
}

# Get VMPooler Guest name
# This is a bit roundabout, but it allows us to detect of the guestinfo.hostname is available or not
# Command is: vmtoolsd.exe --cmd "info-get guestinfo.hostname"'
#
$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = "$($env:ProgramFiles)\VMware\VMware Tools\vmtoolsd.exe"
$pinfo.RedirectStandardError = $true
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false
$pinfo.Arguments = "--cmd ""info-get guestinfo.hostname"""
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $pinfo
$p.Start() | Out-Null
$p.WaitForExit()
$NewVMName = $p.StandardOutput.ReadToEnd().Trim()

# Exit with error code if name not found - likely to be the template machine.
if ($p.ExitCode -ne 0){
  Write-Warning "Could not find VM name in vSphere!`n"
  Write-Warning "If this machine is the template VM, no rename necessary!!"
  Write-Warning "Remember to reset the 'RunOnce' registry key by Loading C:\Packer\Config\vmpooler-arm-host.reg"
  Exit 1
}

Write-Output "vSphere VMname: $NewVMName`n"

# Pickup Env Variables defined in "install-cygwin.ps1"
$CygWinShell = "$CygwinDir\bin\sh.exe"
$AdministratorName =  (Get-WmiObject win32_useraccount -Filter "Sid like 'S-1-5-21-%-500'").Name
$AdministratorHome = "$CygwinDir\home\$AdministratorName"

# Set up cygserv Username
Write-Output "Setting SSH Host Configuration"
$qa_root_passwd = Get-Content "$ENV:CYGWINDOWNLOADS\qapasswd"
& $CygWinShell --login -c `'ssh-host-config --yes --privileged --user cyg_server --pwd $qa_root_passwd`'

# Generate ssh keys.
Write-Output "Generate SSH Keys"
& $CygWinShell --login -c `'rm -rf /home/$AdministratorName/.ssh/id_rsa*`'
& $CygWinShell --login -c `'ssh-keygen -t rsa -N `"`" -f /home/$AdministratorName/.ssh/id_rsa`'

# Setup Authorised keys (now that home directory exists - with nasty cygpath conversion
Write-Output "Setup Authorised Keys"
& $CygWinShell --login -c `'cp /home/$AdministratorName/.ssh/id_rsa.pub /home/$AdministratorName/.ssh/authorized_keys`'
& $CygWinShell --login -c `'cat "/cygdrive/c/Packer/Config/authorized_keys.vmpooler" `>`> /home/$AdministratorName/.ssh/authorized_keys`'

# Setup LSA Authentication
Write-Output "Register the Cygwin LSA authentication package "
& $CygWinShell --login -c `'auto_answer="yes" /usr/bin/cyglsa-config`'

# Add github.com as a known host (needed for git@gihub:<repo> clone ops)
& $CygWinShell --login -c `'ssh-keyscan -t rsa github.com `>`> /home/$AdministratorName/.ssh/known_hosts`'

# Set Startup script (does very little except run bkginfo and set passwd/group)
Write-Output "Setting startup script"
reg import C:\Packer\Config\vmpooler-clone-arm-startup.reg

# Update machine password (and reset autologin)
Write-Output "Setting $AdministratorName Password"
net user $AdministratorName "$qa_root_passwd"
autologon -AcceptEula $AdministratorName . "$qa_root_passwd"

# Generate passwd and group files.
Write-Output "Generating Passwd Files"
$CygwinMkpasswd = "$CygwinDir\bin\mkpasswd.exe -l"
$CygwinMkgroup = "$CygwinDir\bin\mkgroup.exe -l"
$CygwinPasswdFile = "$CygwinDir\etc\passwd"
$CygwinGroupFile = "$CygwinDir\etc\group"
Invoke-Expression $CygwinMkpasswd | Out-File $CygwinPasswdFile -Force -Encoding "ASCII"
Invoke-Expression $CygwinMkgroup | Out-File $CygwinGroupFile -Force -Encoding "ASCII"

# NIC Power Management - ignore any errors as need host-rename to proceed.
Write-Output "Disabling NIC Power Management"
try {
  C:\Packer\Scripts\DisableNetworkAdapterPnPCapabilities.ps1
} catch {
  Write-Warning "Disable Power Management failed"
}

# Although Get-NetAdapter is availble in PS3/5 it is NOT available on Windows-7/2008R2
if ((($PSVersionTable.PSVersion.Major) -ge 4) -and ($WindowsVersion -notlike $WindowsServer2008R2) ) {
  # Disable IPV6 on all network adapters (mainly to stop discovery pings causing firefall errors)
  # The cmdlets are only available on PSVersion 4.0 or later, so only really doing this for win-2012+
  Write-Output "Disabling IPV6 on network adapters"
  Get-NetAdapter | ForEach-Object { Disable-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 }
  Get-NetAdapter | ForEach-Object  { Get-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 }
}
else {
  Write-Output "Skipping IPV6 Disablement"
}

# Set Service startups following the reboot/rename operation.
Write-Output "Re-enable NETBios and WinRM Services"
Set-Service "lmhosts" -StartupType Automatic
Set-Service "netbt" -StartupType Automatic
Set-Service "WinRM" -StartupType Automatic
Write-Output "Set SSHD to start after next boot"
Set-Service "sshd" -StartupType Automatic

# Create BGINFO Scheduled Task to update the lifetime every 20 minutes
schtasks /create /tn UpdateBGInfo /ru "$AdministratorName" /RP "$qa_root_passwd" /F /SC Minute /mo 20 /IT /TR 'C:\Packer\Scripts\sched-bginfo.vbs'
schtasks /run /tn UpdateBGInfo

# Rename this machine to that of the VM name in vSphere
# Windows 7/2008R2- and earlier doesn't use the Rename-Computer cmdlet
Write-Output "Renaming Host to $NewVMName"
if ($WindowsVersion -like $WindowsServer2008R2 -or $WindowsVersion -like $WindowsServer2008) {
  $(gwmi win32_computersystem).Rename("$NewVMName")
  shutdown /t 0 /r /f
}
else {
  Rename-Computer -Newname $NewVMName -Restart
}
Exit 0
