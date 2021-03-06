<#
.SYNOPSIS  
    

.EXAMPLE
    .\Meta-Blue.ps1

.NOTES  
    File Name      : Meta-Blue.ps1
    Version        : v.0.1
    Author         : newhandle
    Prerequisite   : PowerShell
    Created        : 1 Oct 18
    Change Date    : June 7th 2020
    
#>

$timestamp = (get-date).Tostring("yyyy_MM_dd_hh_mm_ss")

Set-Item WSMan:\localhost\Shell\MaxShellsPerUser -Value 10000
Set-Item WSMan:\localhost\Plugin\microsoft.powershell\Quotas\MaxShellsPerUser -Value 10000
Set-Item WSMan:\localhost\Plugin\microsoft.powershell\Quotas\MaxShells -Value 10000

<#
    Define the root directory for results. CHANGE THIS TO BE WHEREVER YOU WANT.
#>
$outFolder = "C:\Meta-Blue\$timestamp"
$rawFolder = "$outFolder\raw"
$jsonFolder = "C:\MetaBlue Results"

if(!(test-path $outFolder)){
    new-item -itemtype directory -path $outFolder -Force
}
if(!(test-path $rawFolder)){
    new-item -itemtype directory -path $rawFolder -Force
}
if(!(test-path $jsonFolder)){
    new-item -itemtype directory -path $jsonFolder -Force
}

$adEnumeration = $false
$winrm = $true
$localBox = $false
$waitForJobs = ""
$runningJobThreshold = 5
$jobTimeOutThreshold = 20

$nodeList = [System.Collections.ArrayList]@()

<#
    This function will convert a folder of csvs to json.
#>
function Make-Json{

    do{
        $json = Read-Host "Do you want to convert to json for forwarding?(y/n)"

        if($json -ieq 'n'){
            return $false
        }elseif($json -ieq 'y'){
            foreach ($file in Get-ChildItem $rawFolder){
                $name = $file.basename
                Import-Csv $file.fullname | ConvertTo-Json | Out-File "$jsonFolder\$name.json"
            }
            return $true
        }else{
            Write-Host "Not a valid option"
        }
    }while($true)
    
}

function Shipto-Splunk{
    do{
        $splunk = Read-Host "Do you want to ship to splunk?(Y/N)"
        if($splunk -ieq 'y'){
            foreach($file in Get-ChildItem $rawFolder){
                Copy-Item -Path $file.FullName -Destination $jsonFolder
            }
            return $true
        }elseif($splunk -ieq 'n'){
            return $false
        }else{
            Write-Host -ForegroundColor Red "[-]Not a valid option."
        }
    }while($true)
}

function Get-FileName($initialDirectory){
<#
    This was taken from: 
    https://social.technet.microsoft.com/Forums/office/en-US/0890adff-43ea-4b4b-9759-5ac2649f5b0b/getcontent-with-open-file-dialog?forum=winserverpowershell
#>   
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null

    $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $OpenFileDialog.initialDirectory = $initialDirectory
    $OpenFileDialog.filter = "All files (*.*)| *.*"
    $OpenFileDialog.ShowDialog() | Out-Null
    $OpenFileDialog.filename
}

function Repair-PSSessions{
    $sessions = Get-PSSession
    $sessions | ?{$_.state -eq "Disconnected"} | Connect-PSSession
    $sessions | ?{$_.state -eq "Broken"} | New-PSSession -SessionOption (New-PSSessionOption -NoMachineProfile -MaxConnectionRetryCount 5)
    Get-PSSession | ?{$_.state -eq "Broken"} | Remove-PSSession 
}

function Create-Artifact{
<#
    There are two ways to use Create-Artifact. The first way, stores all information on a computer by 
    computer basis in their own individual folders. The second way, which is the primary use case,
    creates a single CSV per artifact for data stacking.
#>
    Repair-PSSessions
    
    $poll = $true
    while($poll){
        
        Get-job | ft
        foreach($job in (get-job)){

            $time = (Get-date)
            $elapsed = ($time - $job.PSBeginTime).minutes
            
            if(($job.state -eq "completed")){

                $ComputerName = $job.Location

                $Task = $job.name
                
                if($Task -ne "Prefetch"){

                    <#
                        Comment this if-else if you don't want data stacking format.
                    #>
                    $OS = ($nodeList |?{$_.hostname -eq $ComputerName.toUpper()}).operatingsystem
                    if(($OS -like "*pro*") -or ($OS -like "*Enterprise*")){
                    #if($windowsHosts.contains($computername.toUpper())){
                        Receive-Job $job.id | export-csv -force -append -NoTypeInformation -path "$rawFolder\Host $Task.csv" | out-null
                    }
                    elseif($OS -like "*Server*"){
                    #elseif($windowsServers.Contains($ComputerName.toUpper())){
                        Receive-Job $job.id | export-csv -force -append -NoTypeInformation -path "$rawFolder\Server $Task.csv" | out-null
                    }else{
                        Receive-Job $job.id | export-csv -force -append -NoTypeInformation -path "$rawFolder\Unknown $Task.csv" | out-null
                    }
                #This is for prefetch.
                }
                else{
                
                    Receive-Job $job.id | out-null
                }if(!($job.hasmoredata)){
                    remove-job $job.id -force 
                }
                
            }
            <#
                TODO:
                This stores the info of a failed job. Need to implement some form of retrying failed job.
            #>
            elseif($job.state -eq "failed"){

                $job | export-csv -Append -NoTypeInformation "$outFolder\failedjobs.csv"
                Remove-Job $job.id -force

            }
            elseif(($elapsed -ge $jobTimeOutThreshold) -and ($job.state -ne "Completed")){
                $job | stop-job
            }
            elseif($job.state -eq "Running"){
                continue
            }
        }Start-Sleep -Seconds 8
        if((get-job | where state -eq "completed" |measure).Count -eq 0){
            if((get-job | where state -eq "failed" |measure).Count -eq 0){
                if((get-job | where state -eq "Running" |measure).Count -lt $runningJobThreshold){
                    $poll = $false
                }                
            }
        }
    }
}

function Audit-Snort{
<#
    This function asks for a csv with a cve header from an acas vulnerability scan.
    Then, it just needs to be pointed to whatever rules file from security onion.
    It will create two text files, one with the list of mitigated cves, and the other
    with unmitigated cves.
#>
    'Please select cve list:'
    $vulns = Get-FileName
    'Please select snort rule file:'
    $rules = Get-FileName
    $vulns = import-csv $vulns
    foreach($i in $vulns){
        if(Select-String $i.cve.substring(4) $rules){
            Write-Host -ForegroundColor Green $i.cve "has an associated rule."
            $i.cve >> "$outFolder\MitigatedRules $timestamp.txt"

        }else{
            Write-Host -ForegroundColor Red $i.cve "has no associated rule."
            $i.cve >> "$outFolder\UnmitigatedRules $timestamp.txt"
        }
    
    }
}

function Get-SubnetRange {
<#
    Thank you mr sparkly markley for this super awesome cool subnetrange generator.
#>
    [CmdletBinding(DefaultParameterSetName = "Set1")]
    Param(
        [Parameter(
        Mandatory          =$true,
        Position           = 0,
        ValueFromPipeLine  = $false,
        ParameterSetName   = "Set1"
        )]
        [ValidatePattern(@"
^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){3}$
"@
        )]
            [string]$IPAddress,



        [Parameter(
        Mandatory          =$true,
        ValueFromPipeline  = $false,
        ParameterSetName   = "Set1"
        )]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern(@"
^([0-9]|[0-2][0-9]|3[0-2]|\/([0-9]|[0-2][0-9]|3[0-2]))$
"@
        )]
            [string]$CIDR

)
$IPSubnetList = [System.Collections.ArrayList]@()

#Ip Address in Binary #######################################
$Binary  = $IPAddress -split '\.' | Foreach {
    [System.Convert]::ToString($_,2).Padleft(8,'0')}
$Binary = $Binary -join ""


#Host Bits from CIDR #######################################
if ($CIDR -like '/*') {
$CIDR = ($CIDR -split '/')[1] }
$HostBits = 32 - $CIDR



$NetworkIDinBinary = $Binary.Substring(0,$CIDR)
$FirstHost = $NetworkIDinBinary.Padright(32,'0')
$LastHost = $NetworkIDinBinary.padright(32,'1')

#Getting IP of Hosts #######################################
$x = 1


while ($FirstHost -lt $LastHost) {
   
    $Octet1 = $FirstHost[0..7] -join "" | foreach {[System.Convert]::ToByte($_,2)}
    $Octet2 = $FirstHost[8..15] -join "" | foreach {[System.Convert]::ToByte($_,2)}
    $Octet3 = $FirstHost[16..23] -join "" | foreach {[System.Convert]::ToByte($_,2)}
    $Octet4 = $FirstHost[24..31] -join "" | foreach {[System.Convert]::ToByte($_,2)}

    $NewIPAddress = $Octet1,$Octet2,$Octet3,$Octet4 -join "."

    if(!($NewIPAddress -like "*.0")){
        $IPSubnetList.add($NewIPAddress) | out-null
    }
    $NetworkBitsinBinary = $FirstHost.Substring(0,$FirstHost.Length-$HostBits)

    $xInBinary = [System.Convert]::ToString($x,2).padleft($HostBits,'0')

    $FirstHost = $NetworkBitsinBinary+$xInBinary

    ++$x

    }

# Adds Last IP because the while loop refuses to for whatever reason #
    $Octet1 = $LastHost[0..7] -join "" | foreach {[System.Convert]::ToByte($_,2)}
    $Octet2 = $LastHost[8..15] -join "" | foreach {[System.Convert]::ToByte($_,2)}
    $Octet3 = $LastHost[16..23] -join "" | foreach {[System.Convert]::ToByte($_,2)}
    $Octet4 = $LastHost[24..31] -join "" | foreach {[System.Convert]::ToByte($_,2)}

    
    $NewIPAddress = $Octet1,$Octet2,$Octet3,$Octet4 -join "."
    
    if(!($NewIPAddress -like "*.255")){
        $IPSubnetList.add( $NewIPAddress) | out-null
    }

# Calls on IP List #######################################
   return $IPSubnetList
}


function Enumerator([System.Collections.ArrayList]$iparray){
<#
    TODO: We need to add a method for determining windows hosts past ICMP. 
    we can test-netconnection -port 135 and test-netconnection -commontcpport smb
    TODO: For everything that is left after that, banner grab 22 because  that should help
    identify linux devices.
    TODO: Past that, consult something else.
#>
<#
    Enumerator asynchronously pings and asynchronously performs DNS name resolution.
#>
    if($adEnumeration){
        Write-host -ForegroundColor Green "[+]Checking Windows OS Type"
   
        foreach($i in $iparray){
            if($i -ne $null){                
                    (Invoke-Command -ComputerName $i -ScriptBlock  {(gwmi win32_operatingsystem).caption} -AsJob -JobName $i) | out-null               
                    }
                }get-job | wait-job | out-null
       }
    else{
        <#
            Asynchronously Ping
        #>
        $task = foreach($ip in $iparray){
            ((New-Object System.Net.NetworkInformation.Ping).SendPingAsync($ip))
        }[threading.tasks.task]::WaitAll($task)

        
        $addresses = foreach($i in $task.result){($i.address).Ipaddresstostring}
        
        $addresses = ($addresses |group |select count,name |sort count).name | ?{$_ -ne "0.0.0.0"}

        $result = $task.Result
        $result = $result | ?{$_.status -eq "Success"}
        foreach($i in $result){
            $nodeObj = [PSCustomObject]@{
                HostName = ""
                IPAddress = ""
                OperatingSystem = ""
                TTL = 0
            }
            $nodeObj.IPAddress = $i.Address.IPAddressToString
            $nodeObj.TTL = $i.Options.ttl
            $nodeList.Add($nodeObj) | Out-Null
        }

        write-host -ForegroundColor Green "[+]There are" ($result | measure).count "total live hosts."

        foreach($i in $nodeList){
            $ttl = $i.ttl
            if($ttl -le 64 -and $ttl -ge 45){
                $i.OperatingSystem = "*NIX"
            }elseif($ttl -le 128 -and $ttl -ge 115){
                $i.OperatingSystem = "Windows"
            
            }elseif($ttl -le 255 -and $ttl -ge 230){
                $i.OperatingSystem = "Cisco"
            }
        }

        Write-Host -ForegroundColor Green "[+]Connection Testing Complete beep boop beep"
        Write-Host -ForegroundColor Green "[+]Starting Reverse DNS Resolution"

        <#
            Asynchronously Resolve DNS Names
        #>
        $dnsTask = foreach($i in $addresses){
                    [system.net.dns]::GetHostEntryAsync($i)
                    
        }[threading.tasks.task]::WaitAll($dnsTask) | out-null

        $dnsTask = $dnsTask | ?{$_.status -ne "Faulted"}

        foreach($i in $dnsTask){
            foreach($j in $nodeList){
                $hostname = (($i.result.hostname).split('.')[0]).toUpper()
                $ip = ($i.result.addresslist.Ipaddresstostring)
                if($ip -ne $null -and $hostname -ne $Null){
                    if($ip -eq $j.ipaddress){
                        $j.hostname = $hostname
                    }
                }
            }
        }

            
        Write-Host -ForegroundColor Green "[+]Reverse DNS Resolution Complete"   

        Write-host -ForegroundColor Green "[+]Checking Windows OS Type"

        foreach($i in $nodeList){
            if(($i.operatingsystem -eq "Windows")){
                $comp = $i.ipaddress
                Write-Host -ForegroundColor Green "Starting OS ID Job on:" $comp
                Start-Job -Name $comp -ScriptBlock {gwmi win32_operatingsystem -ComputerName $using:comp -ErrorAction SilentlyContinue}|Out-Null
            }
        }
        
    }
    Write-Host -ForegroundColor Green "[+]All OS Jobs Started"
    
    $poll = $true
    
    $refTime = (Get-Date)
    while($poll){
        foreach($job in (get-job)){
            $time = (Get-Date)
            $elapsed = ($time - $job.PSBeginTime).minutes
            if($job.state -eq "completed"){

                 $osinfo = Receive-Job $job -ErrorAction SilentlyContinue
                 remove-job $job
                 if($osinfo -ne $null){

                    $hostname = (($osinfo.CSName).split('.')[0]).toUpper()
                    
                    foreach($i in $nodeList){
                        if($i.IPAddress -eq $job.name){
                            $i.hostname = $hostname
                            $i.operatingsystem =$osinfo.caption
                        }
                    }
                }
            }
            elseif($job.State -eq "failed"){
                Remove-Job $job.id -Force
            }
            elseif(($elapsed -ge $jobTimeOutThreshold) -and ($job.state -ne "Completed")){
                Write-Host "Stopping Job:" $job.Name
                $job | stop-job
            }
        }Start-Sleep -Seconds 8
        if((get-job | where state -eq "completed" |measure).Count -eq 0){
            if((get-job | where state -eq "failed" |measure).Count -eq 0){
                if((get-job | where state -eq "Running" |measure).Count -lt $runningJobThreshold){
                    $poll = $false
                    Write-Host "Total Elapsed:" ((get-date) - $refTime).Minutes
                }
            }
        }
    }
    <#
        Create the DnsMapper.csv
    #>
    $nodeList.getEnumerator() | Select-Object -Property @{N='HostName';E={$_.hostname}},@{N='IPAddress';E={$_.IPAddress}},@{N='OperatingSystem';E={$_.OperatingSystem}},@{N='TTL';E={$_.TTL}} | Export-Csv -path "$outfolder\NodeList.csv" -NoTypeInformation
    Write-Host -ForegroundColor Green "[+]NodeList.csv created"

    Get-Job
    write-host -ForegroundColor Green "Operating System identification jobs are done."    

    Get-Job | ?{$_.state -ne "Stopped"} | Remove-Job -Force

}

function Memory-Dumper{
    #TODO:Adapt this for other memory dump solutions like dumpit
     <#
        Create individual folders and files under $home\desktop\Meta-Blue
     #>
    foreach($i in $dnsMappingTable.Values){
        if(!(test-path $outFolder\$i)){
            new-item -itemtype directory -path $outFolder\$i -force
        }
    }
    
    Write-host -ForegroundColor Green "Begin Memory Dumping"

    <#
        Create PSSessions
    #>
    foreach($i in $windowsHosts){
        Write-host "Starting PSSession on" $i
        New-pssession -computername $i -name $i | out-null
    }
    foreach($i in $windowsServers){
        Write-host "Starting PSSession on" $i
        New-pssession -computername $i -credential $socreds -name $i | out-null
    }

    if((Get-PSSession | measure).count -eq 0){
        return
    }

    write-host -ForegroundColor Green "There are" ((Get-PSSession | measure).count) "Sessions."

    foreach($i in (Get-PSSession)){
        if(!(invoke-command -session $i -ScriptBlock { Test-Path "c:\winpmem-2.1.post4.exe" })){
            Write-host -ForegroundColor Green "Select winpmem-2.1.post4.exe location:"
            Copy-Item -ToSession $i $(Get-FileName) -Destination "c:\"
        }        
        Invoke-Command -Session $i -ScriptBlock {rm "$home\documents\memory.aff4" -ErrorAction SilentlyContinue}
        Write-Host "Starting Memory Dump on" $i.computername       
        Invoke-Command -session $i -ScriptBlock  {"$(C:\winpmem-2.1.post4.exe -o memory.aff4)" } -asjob -jobname "Memory Dumps" | Out-Null 
        
    }get-job | wait-job

    Write-host "Collecting Memory Dumps"
    foreach($i in (Get-PSSession)){
        $name = $i.computername
        Write-Host "Collecting" $name "'s dump"
        Copy-Item -FromSession $i "$home\documents\memory.aff4" -Destination "$outFolder\$name memorydump"
    }

    Get-PSSession | Remove-PSSession
    get-job | remove-job -Force

}

<#
    MITRE ATT&CK: T1015
#>
function AccessibilityFeature{
    Write-host "Starting AccessibilityFeature Jobs"
    if($localBox){
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\*' | export-csv -NoTypeInformation -Append "$outFolder\Local AccessibilityFeature.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\*' | select DisableExeptionChainValidation,MitigationOptions,PSPath,PSChildName,PSComputerName}  -asjob -jobname "AccessibilityFeature") | out-null
        }
        Create-Artifact
    }
}

function InstalledSoftware{
    Write-host "Starting InstalledSoftware Jobs"
    if($localBox){
        $(Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*; 
        Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*;
        New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS| Out-Null;
        $UserInstalls += gci -Path HKU: | where {$_.Name -match 'S-\d-\d+-(\d+-){1,14}\d+$'} | foreach {$_.PSChildName };
        $(foreach ($User in $UserInstalls){Get-ItemProperty HKU:\$User\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*});
        $UserInstalls = $null;try{Remove-PSDrive -Name HKU}catch{};)|where {($_.DisplayName -ne $null) -and ($_.Publisher -ne $null)} | export-csv -NoTypeInformation -Append "$outFolder\Local InstalledSoftware.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {
                $(Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*; 
                Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*;
                New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS| Out-Null;
                $UserInstalls += gci -Path HKU: | where {$_.Name -match 'S-\d-\d+-(\d+-){1,14}\d+$'} | foreach {$_.PSChildName };
                $(foreach ($User in $UserInstalls){Get-ItemProperty HKU:\$User\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*});
                $UserInstalls = $null;try{Remove-PSDrive -Name HKU}catch{};)|where {($_.DisplayName -ne $null) -and ($_.Publisher -ne $null)}
            }  -asjob -jobname "InstalledSoftware") | out-null
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1100
#>
function WebShell{
    Write-host "Starting WebShell Jobs"
    if($localBox){
        gci -path "C:\inetpub\wwwroot" -recurse -File -ea SilentlyContinue | Select-String -Pattern "runat" | export-csv -NoTypeInformation -Append "$outFolder\Local WebShell.csv" | Out-Null
        gci -path "C:\inetpub\wwwroot" -recurse -File -ea SilentlyContinue | Select-String -Pattern "eval" | export-csv -NoTypeInformation -Append "$outFolder\Local WebShell.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {
                gci -path "C:\inetpub\wwwroot" -recurse -File -ea SilentlyContinue | Select-String -Pattern "runat";
                gci -path "C:\inetpub\wwwroot" -recurse -File -ea SilentlyContinue | Select-String -Pattern "eval"
            }  -asjob -jobname "WebShell") | out-null
        }
        Create-Artifact
    }
}

function Processes{
    Write-host "Starting Process Jobs"
    if($localBox){
        gwmi win32_process | export-csv -NoTypeInformation -Append "$outFolder\Local Processes.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_process}  -asjob -jobname "Processes") | out-null
        }
        Create-Artifact
    }
}

function DNSCache{
    Write-host "Starting DNSCache Jobs"
    if($localBox){
        Get-DnsClientCache | export-csv -NoTypeInformation -Append "$outFolder\Local DNSCache.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {Get-DnsClientCache -ErrorAction SilentlyContinue}  -asjob -jobname "DNSCache") | out-null
        }
        Create-Artifact
    }
}

function ProgramData{
    Write-host "Starting ProgramData Enum"
    if($localBox){
        Get-ChildItem -Recurse C:\ProgramData | export-csv -NoTypeInformation -Append "$outFolder\Local ProgramData.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-ChildItem -Recurse c:\ProgramData\}  -asjob -jobname "ProgramData")| out-null         
        }
        Create-Artifact
    }
}

function AlternateDataStreams{
    Write-host "Starting AlternateDataStreams Enum"
    if($localBox){
        Set-Location C:\Users
        (Get-ChildItem -Recurse).fullname | Get-Item -Stream * | ?{$_.stream -ne ':$DATA'} | export-csv -NoTypeInformation -Append "$outFolder\Local AlternateDataStreams.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Set-Location C:\Users; (Get-ChildItem -Recurse).fullname | Get-Item -Stream * | ?{$_.stream -ne ':$DATA'} }  -asjob -jobname "AlternateDataStreams")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1128
#>
function NetshHelperDLL{
    Write-host "Starting NetshHelperDLL Enum"
    if($localBox){
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Netsh') | export-csv -NoTypeInformation -Append "$outFolder\Local NetshHelperDLL.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Netsh')} -asjob -jobname "NetshHelperDLL")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1013
#>
function PortMonitors{
    Write-host "Starting PortMonitors Enum"
    if($localBox){
        (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\*") | export-csv -NoTypeInformation -Append "$outFolder\Local PortMonitors.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\*")}  -asjob -jobname "PortMonitors")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1038
#>
function KnownDLLs{
    Write-host "Starting KnownDLLs Enum"
    if($localBox){
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs\') | export-csv -NoTypeInformation -Append "$outFolder\Local KnownDLLs.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs\')}  -asjob -jobname "KnownDLLs")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1038
#>
function DLLSearchOrderHijacking{
    Write-host "Starting DLLSearchOrderHijacking Enum"
    if($localBox){
        (gci -path C:\Windows\* -include *.dll | Get-AuthenticodeSignature | Where-Object Status -NE "Valid") | export-csv -NoTypeInformation -Append "$outFolder\Local DLLSearchOrderHijacking.csv" | Out-Null
        (gci -path C:\Windows\System32\* -include *.dll | Get-AuthenticodeSignature | Where-Object Status -NE "Valid") | export-csv -NoTypeInformation -Append "$outFolder\Local DLLSearchOrderHijacking.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {}  -asjob -jobname "DLLSearchOrderHijacking")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1197
#>
function BITSJobs{
    Write-host "Starting BITSJobs Enum"
    if($localBox){
        Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Bits-Client/Operational'; Id='59'} | export-csv -NoTypeInformation -Append "$outFolder\Local BITSJobs.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Bits-Client/Operational'; Id='59'} }  -asjob -jobname "BITSJobs")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1019
#>
function SystemFirmware{
    Write-host "Starting SystemFirmware Enum"
    if($localBox){
        Get-WmiObject win32_bios | export-csv -NoTypeInformation -Append "$outFolder\Local SystemFirmware.csv" | Out-Null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-WmiObject win32_bios}  -asjob -jobname "SystemFirmware")| out-null         
        }
        Create-Artifact
    }
}

function LogonScripts{
    Write-host "Starting LogonScripts Enum"
    if($localBox){
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {
                 New-PSDrive HKU Registry HKEY_USERS -ErrorAction SilentlyContinue | Out-Null;
                 Set-Location HKU: | Out-Null;
                 (Get-ChildItem -ErrorAction SilentlyContinue| %{test-path "$($_.name)\Environment\UserInitMprLogonScript"})   
             
             }  -asjob -jobname "LogonScripts")| out-null         
        }
        Create-Artifact
    }
}

function Registry{
<#
        You can add anything you want here but should reserve it for registry queries. The queries get added in as
        noteproperties to the PSCustomObject so that they can be exported to CSV in a stackable format. If the registry
        key is an array, typecast to a string. Ensure you pick a property name that reflects the forensic relavence of
        the registry location.
#>
    Write-host "Starting Registry Jobs"

    New-PSDrive HKU Registry HKEY_USERS
    Set-Location HKU:

    if($localBox){
        $logonScripts = @()

        foreach($i in (Get-ChildItem).name){if(test-path "$i\Environment\UserInitMprLogonScript"){$logonScripts += [String]$i}}

        $registry = [PSCustomObject]@{
                
                <#
                    MITRE ATT&CK: T1182
                #>
                AppCertDLLs = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\appcertdlls\')

                LogonScripts = [String]$logonScripts

                BootShell = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\' -ErrorAction SilentlyContinue).bootshell

                BootExecute = [String](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\' -ErrorAction SilentlyContinue).bootexecute

                NetworkList = [String]((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\UnManaged\*' -ErrorAction SilentlyContinue).dnssuffix)
                
                <#
                        MITRE ATT&CK: T1131
                #>
                AuthenticationPackage = [String]((get-itemproperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\ -ErrorAction SilentlyContinue).('authentication packages'))

                HKLMRun = [String](get-item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run\' -ErrorAction SilentlyContinue).property
                HKCURun = [String](get-item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\' -ErrorAction SilentlyContinue).property
                HKLMRunOnce = [String](get-item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce\' -ErrorAction SilentlyContinue).property
                HKCURunOnce = [String](Get-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce\' -ErrorAction SilentlyContinue).property

                Shell = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\' -ErrorAction SilentlyContinue).shell

                Manufacturer = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation\' -ErrorAction SilentlyContinue).manufacturer

                <#
                        MITRE ATT&CK: T1103
                #>
                AppInitDlls = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction SilentlyContinue).appinit_dlls

                ShimCustom = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Custom' -ErrorAction SilentlyContinue)

                UserInit = [String](Get-ItemProperty ('HKLM:\software\Microsoft\Windows NT\CurrentVersion\Winlogon\') -ErrorAction SilentlyContinue).userinit

                Powershellv2 = if((test-path HKLM:\SOFTWARE\Microsoft\PowerShell\1\powershellengine\)){$true}else{$false}
            }
            $registry | Export-Csv -NoTypeInformation -Append "$outFolder\Local Registry.csv"
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {                
                New-PSDrive HKU Registry HKEY_USERS -ErrorAction SilentlyContinue | Out-Null;
                Set-Location HKU: | Out-Null;

                $registry = [PSCustomObject]@{
                    
                    <#
                        MITRE ATT&CK: T1182
                    #>
                    AppCertDLLs = (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\appcertdlls\')

                    LogonScripts = [String](Get-ChildItem | %{test-path "$($_.name)\Environment\UserInitMprLogonScript"})

                    BootShell = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\' -ErrorAction SilentlyContinue).bootshell

                    BootExecute = [String](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\' -ErrorAction SilentlyContinue).bootexecute

                    NetworkList = [String]((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\UnManaged\*' -ErrorAction SilentlyContinue).dnssuffix)
                    
                    <#
                        MITRE ATT&CK: T1131
                    #>
                    AuthenticationPackage = [String]((get-itemproperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\ -ErrorAction SilentlyContinue).('authentication packages'))

                    HKLMRun = [String](get-item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run\' -ErrorAction SilentlyContinue).property
                    HKCURun = [String](get-item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\' -ErrorAction SilentlyContinue).property
                    HKLMRunOnce = [String](get-item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce\' -ErrorAction SilentlyContinue).property
                    HKCURunOnce = [String](Get-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce\' -ErrorAction SilentlyContinue).property

                    Shell = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\' -ErrorAction SilentlyContinue).shell

                    Manufacturer = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation\' -ErrorAction SilentlyContinue).manufacturer

                    <#
                        MITRE ATT&CK: T1103
                    #>
                    AppInitDlls = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction SilentlyContinue).appinit_dlls

                    ShimCustom = [String](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Custom' -ErrorAction SilentlyContinue)

                    UserInit = [String](Get-ItemProperty ('HKLM:\software\Microsoft\Windows NT\CurrentVersion\Winlogon\') -ErrorAction SilentlyContinue).userinit

                    Powershellv2 = if((test-path HKLM:\SOFTWARE\Microsoft\PowerShell\1\powershellengine\)){$true}else{$false}
                }
                $registry
        
            }  -asjob -jobname "Registry") | out-null
        }
        Create-Artifact
    }
}

function AVProduct{
    Write-host "Starting AVProduct Jobs"
    if($localBox){
       Get-WmiObject -Namespace "root\SecurityCenter2" -Class AntiVirusProduct -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Append "$outFolder\Local AVProduct.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {Get-WmiObject -Namespace "root\SecurityCenter2" -Class AntiVirusProduct -ErrorAction SilentlyContinue}  -asjob -jobname "AVProduct") | out-null
        }
        Create-Artifact
    }
    
}

function Services{
    Write-host "Starting Services Jobs"
    if($localBox){
        gwmi win32_service | export-csv -NoTypeInformation -Append "$outFolder\Local Services.csv" | Out-Null
    }else{ 
        foreach($i in (Get-PSSession)){         
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_service}  -asjob -jobname "Services")| out-null
        }
        Create-Artifact
    }
}

function PoshVersion{
    Write-host "Starting PoshVersion Jobs"
    if($localBox){
        Get-WindowsOptionalFeature -Online -FeatureName microsoftwindowspowershellv2 | export-csv -NoTypeInformation -Append "$outFolder\Local PoshVersion.csv" | Out-Null
    }else{ 
        foreach($i in (Get-PSSession)){         
            (Invoke-Command -session $i -ScriptBlock  {Get-WindowsOptionalFeature -Online -FeatureName microsoftwindowspowershellv2}  -asjob -jobname "PoshVersion")| out-null
        }
        Create-Artifact
    }
}

function Startup{
    Write-host "Starting Startup Jobs"
    if($localBox){
        gwmi win32_startupcommand | export-csv -NoTypeInformation -Append "$outFolder\Local Startup.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){   
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_startupcommand}  -asjob -jobname "Startup")| out-null         
        }
        Create-Artifact
    }
}

<#
    MITRE ATT&CK: T1060
#>
function StartupFolder{
    Write-host "Starting StartupFolder Jobs"
    if($localBox){
        gci -path "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*" -include *.lnk,*.url -ErrorAction SilentlyContinue | export-csv -NoTypeInformation -Append "$outFolder\Local StartupFolder.csv" | out-null
        gci -path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\*" -include *.lnk,*.url -ErrorAction SilentlyContinue | export-csv -NoTypeInformation -Append "$outFolder\Local StartupFolder.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){   
            (Invoke-Command -session $i -ScriptBlock  {
                gci -path "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*" -include *.lnk,*.url -ErrorAction SilentlyContinue;
                gci -path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\*" -include *.lnk,*.url -ErrorAction SilentlyContinue
            }  -asjob -jobname "StartupFolder")| out-null         
        }
        Create-Artifact
    }
}

function Drivers{
    Write-host "Starting Driver Jobs"
    if($localBox){
        gwmi win32_systemdriver | export-csv -NoTypeInformation -Append "$outFolder\Local Drivers.csv" | Out-Null
    }else{ 
        foreach($i in (Get-PSSession)){         
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_systemdriver}  -asjob -jobname "Drivers")| out-null         
        }
        Create-Artifact
    }
}

function DriverHash{
    Write-host "Starting DriverHash Jobs"
    if($localBox){
        $driverPath = (gwmi win32_systemdriver).pathname          
            foreach($driver in $driverPath){                
                    (Get-filehash -algorithm SHA256 -path $driver -ErrorAction SilentlyContinue) | export-csv -NoTypeInformation -Append "$outFolder\Local DriverHashes.csv" | out-null                
            }
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {
                $driverPath = (gwmi win32_systemdriver).pathname          
                foreach($driver in $driverPath){                
                        (Get-filehash -algorithm SHA256 -path $driver -ErrorAction SilentlyContinue)                
                }
            }  -asjob -jobname "DriverHash") | out-null
        }
        Create-Artifact
    }
}

function EnvironVars{
    Write-host "Starting EnvironVars Jobs"
    if($localBox){
        gwmi win32_environment | export-csv -NoTypeInformation -Append "$outFolder\Local EnvironVars.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){         
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_environment}  -asjob -jobname "EnvironVars")| out-null         
        }
        Create-Artifact
    }  
}

function NetAdapters{
    Write-host "Starting NetAdapter Jobs"
    if($localBox){
        gwmi win32_networkadapterconfiguration | Export-Csv -NoTypeInformation -Append "$outFolder\Local NetAdapters.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){         
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_networkadapterconfiguration}  -asjob -jobname "NetAdapters")| out-null        
        }
        Create-Artifact
    }
}

function SystemInfo{
    Write-host "Starting SystemInfo Jobs"
    if($localBox){
        gwmi win32_computersystem | export-csv -NoTypeInformation -Append "$outFolder\Local Systeminfo.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {gwmi win32_computersystem}  -asjob -jobname "SystemInfo")| out-null         
        }
        Create-Artifact
    }
}

function Logons{
    Write-host "Starting Logon Jobs"
    if($localBox){
        gwmi win32_networkloginprofile | export-csv -NoTypeInformation -Append "$outFolder\Local Logons.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
            (Invoke-Command -session $i -ScriptBlock  {gwmi win32_networkloginprofile}  -asjob -jobname "Logons")| out-null         
        }
        Create-Artifact
    }
}

function NetConns{
    Write-host "Starting NetConn Jobs"
    if($localBox){
        Get-NetTCPConnection | export-csv -NoTypeInformation -Append "$outFolder\Local NetConn.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
            (Invoke-Command -session $i -ScriptBlock  {get-NetTcpConnection}  -asjob -jobname "NetConn")| out-null        
        }
        Create-Artifact
    }
}

function SMBShares{
    Write-host "Starting SMBShare Jobs"
    if($localBox){
        Get-SmbShare | export-csv -NoTypeInformation -Append "$outFolder\Local SMBShares.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {get-Smbshare}  -asjob -jobname "SMBShares")| out-null        
        }
        Create-Artifact
    }
}

function SMBConns{
    Write-host "Starting SMBConn Jobs"
    if($localBox){
        Get-SmbConnection | export-csv -NoTypeInformation -Append "$outFolder\Local SMBConns.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){         
            (Invoke-Command -session $i -ScriptBlock  {get-SmbConnection}  -asjob -jobname "SMBConns")| out-null      
        }
        Create-Artifact
    }
}

function SchedTasks{
    Write-host "Starting SchedTask Jobs"
    if($localBox){
        Get-ScheduledTask | Export-Csv -NoTypeInformation -Append "$outFolder\Local SchedTasks.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {get-scheduledtask -ErrorAction SilentlyContinue}  -asjob -jobname "SchedTasks")| out-null         
        }
        Create-Artifact
    }
}

function ProcessHash{
    Write-host "Starting Process Hash Jobs"
    if($localBox){
        $hashes = @()
            $pathsofexe = (gwmi win32_process -ErrorAction SilentlyContinue | select executablepath | sort executablepath -Unique | ?{$_.executablepath -ne ""})
            $execpaths = [System.Collections.ArrayList]@();foreach($i in $pathsofexe){$execpaths.Add($i.executablepath)| Out-Null}
            foreach($i in $execpaths){
                if($i -ne $null){
                    (Get-filehash -algorithm SHA256 -path $i -ErrorAction SilentlyContinue) | export-csv -NoTypeInformation -Append "$outFolder\Local ProcessHash.csv" | Out-Null
                }
            }
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {
                $hashes = @()
                $pathsofexe = (gwmi win32_process -ErrorAction SilentlyContinue | select executablepath | sort executablepath -Unique | ?{$_.executablepath -ne ""})
                $execpaths = [System.Collections.ArrayList]@();foreach($i in $pathsofexe){$execpaths.Add($i.executablepath)| Out-Null}
                foreach($i in $execpaths){
                    if($i -ne $null){
                        (Get-filehash -algorithm SHA256 -path $i -ErrorAction SilentlyContinue)
                    }
                }
            }  -asjob -jobname "ProcessHash") | out-null
        }
        Create-Artifact
    }
}

function PrefetchListing{
    Write-host "Starting PrefetchListing Jobs"
    if($localBox){
        Get-ChildItem "C:\Windows\Prefetch" | export-csv -NoTypeInformation -Append "$outFolder\Local PrefetchListing.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-ChildItem "C:\Windows\Prefetch"}  -asjob -jobname "PrefetchListing")| out-null         
        }
        Create-Artifact
    }
}

function PNPDevices{
    Write-host "Starting PNP Device Jobs"
    if($localBox){
        gwmi win32_pnpentity | export-csv -NoTypeInformation -Append "$outFolder\Local PNPDevices.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {gwmi win32_pnpentity}  -asjob -jobname "PNPDevices")| out-null         
        }
        Create-Artifact
    }
}

function LogicalDisks{
    Write-host "Starting Logical Disk Jobs"
    if($localBox){
        gwmi win32_logicaldisk | export-csv -NoTypeInformation -Append "$outFolder\Local LogicalDisks.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {gwmi win32_logicaldisk}  -asjob -jobname "LogicalDisks")| out-null         
        }
        Create-Artifact
    }
}

function DiskDrives{
    Write-host "Starting Disk Drive Jobs"
    if($localBox){
        gwmi win32_diskdrive | export-csv -NoTypeInformation -Append "$outFolder\Local DiskDrives.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {gwmi win32_diskdrive}  -asjob -jobname "DiskDrives")| out-null         
        }
        Create-Artifact
    }
}

function WMIEventFilters{
    Write-host "Starting WMIEventFilter Jobs"
    if($localBox){
        Get-WMIObject -Namespace root\Subscription -Class __EventFilter | Export-Csv -NoTypeInformation -Append "$outFolder\Local WMIEventFilters.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-WMIObject -Namespace root\Subscription -Class __EventFilter}  -asjob -jobname "WMIEventFilters")| out-null         
        }
        Create-Artifact
    }
}

function WMIEventConsumers{
    Write-host "Starting WMIEventConsumer Jobs"
    if($localBox){
        Get-WMIObject -Namespace root\Subscription -Class __EventConsumer | export-csv -NoTypeInformation -Append "$outFolder\Local WMIEventConsumers.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-WMIObject -Namespace root\Subscription -Class __EventConsumer}  -asjob -jobname "WMIEventConsumers")| out-null         
        }
        Create-Artifact
    }
}

function WMIEventConsumerBinds{
    Write-host "Starting WMIEventConsumerBind Jobs"
    if($localBox){
        Get-WMIObject -Namespace root\Subscription -Class __FilterToConsumerBinding | Export-Csv -NoTypeInformation -Append "$outFolder\Local WMIEventConsumerBinds.csv" | Out-Null
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  {Get-WMIObject -Namespace root\Subscription -Class __FilterToConsumerBinding}  -asjob -jobname "WMIEventConsumerBinds")| out-null         
        }
        Create-Artifact
    }
}

function DLLs{
    Write-host "Starting Loaded DLL Jobs"
    if($localBox){
        Get-Process -Module -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Append "$outFolder\Local DLLs.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {Get-Process -Module -ErrorAction SilentlyContinue}  -asjob -jobname "DLLs") | out-null
        }
        Create-Artifact
    }
}

<#
    MITRE ATTACK: T1177
#>
function LSASSDriver{
    Write-host "Starting LSASSDriver Jobs"
    if($localBox){
        Get-WinEvent -FilterHashtable @{ LogName='Security'; Id='4614';} -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Append "$outFolder\Local LSASSDriver.csv" | out-null
        Get-WinEvent -FilterHashtable @{ LogName='Security'; Id='3033';} -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Append "$outFolder\Local LSASSDriver.csv" | out-null
        Get-WinEvent -FilterHashtable @{ LogName='Security'; Id='3063';} -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Append "$outFolder\Local LSASSDriver.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {
            Get-WinEvent -FilterHashtable @{ LogName='Security'; Id='4614';} -ErrorAction SilentlyContinue;
            Get-WinEvent -FilterHashtable @{ LogName='Security'; Id='3033';} -ErrorAction SilentlyContinue;
            Get-WinEvent -FilterHashtable @{ LogName='Security'; Id='3063';} -ErrorAction SilentlyContinue
            } -asjob -jobname "LSASSDriver") | out-null
        }
        Create-Artifact
    }
}

function DLLHash{
    Write-host "Starting Loaded DLL Hashing Jobs"
    if($localBox){
        $a = (Get-Process -Module -ErrorAction SilentlyContinue | ?{!($_.FileName -like "*.exe")})
            $a = $a.FileName.ToUpper() | sort
            $a = $a | Get-Unique
            foreach($file in $a){
                Get-FileHash -Algorithm SHA256 $file | Export-Csv -NoTypeInformation -Append "$outFolder\Local DLLHash.csv" | Out-Null
            }
    }else{
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {
                $a = (Get-Process -Module -ErrorAction SilentlyContinue | ?{!($_.FileName -like "*.exe")})
                $a = $a.FileName.ToUpper() | sort
                $a = $a | Get-Unique
                foreach($file in $a){
                    Get-FileHash -Algorithm SHA256 $file
                }
        
            }  -asjob -jobname "DLLHash") | out-null
        }
        Create-Artifact
    }
}

function UnsignedDrivers{
    Write-host "Starting UnsignedDrivers Jobs"
    if($localBox){
        gci -path C:\Windows\System32\drivers -include *.sys -recurse -ea SilentlyContinue | Get-AuthenticodeSignature | where {$_.status -ne 'Valid'} | Export-Csv -NoTypeInformation -Append "$outFolder\Local UnsignedDrivers.csv" | out-null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  { gci -path C:\Windows\System32\drivers -include *.sys -recurse -ea SilentlyContinue | Get-AuthenticodeSignature | where {$_.status -ne 'Valid'}}  -asjob -jobname "UnsignedDrivers")| out-null         
        }
        Create-Artifact
    }
}

function Hotfix{
    Write-host "Starting Hotfix Jobs"
    if($localBox){
        Get-HotFix -ErrorAction SilentlyContinue| Export-Csv -NoTypeInformation -Append "$outFolder\Local Hotfix.csv" | out-null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  { Get-HotFix -ErrorAction SilentlyContinue}  -asjob -jobname "Hotfix")| out-null         
        }
        Create-Artifact
    }
}

function ArpCache{
    Write-host "Starting ArpCache Jobs"
    if($localBox){
        Get-NetNeighbor| Export-Csv -NoTypeInformation -Append "$outFolder\Local ArpCache.csv" | out-null
    
    }else{
        foreach($i in (Get-PSSession)){
             (Invoke-Command -session $i -ScriptBlock  { Get-NetNeighbor -ErrorAction SilentlyContinue}  -asjob -jobname "ArpCache")| out-null         
        }
        Create-Artifact
    }
}


function Update-Sysmon{
<#
    This can update sysmon for everyone. Change the location of the config file and its name 
    per your environment.
#>
    if(!$localBox){
        do{
            $sysmon = Read-Host "Do you want to update sysmon?(Y/N)"
    
            if($sysmon -ieq 'y'){
                foreach($i in (Get-PSSession)){
                    Write-Host "Updating Sysmon Configs From Sysvol on" $i.computername
                    Copy-Item -ToSession $i -Path $home\Downloads\SysinternalsSuite\Sysmon64.exe -Destination $home\Downloads -force 
                    Copy-Item -ToSession $i -Path $home\Downloads\SysinternalsSuite\sysmonconfig-export.xml -Destination $home\Downloads -force  
                    Invoke-Command -session $i -ScriptBlock  {cd $home\Downloads; $(.\sysmon64.exe -accepteula -i .\sysmonconfig-export.xml)} | out-null
                }
                return $true
            }elseif($sysmon -ieq 'n'){
                return $false   
            }else{
                Write-Host "Not a valid option"
            }
        }while($true)
    }
}


function Find-File{
    if(!$localBox){
        do{
            $findfile = Read-Host "Do you want to find some files?(Y/N)"
            if($findfile -ieq 'y'){
                $fileNames = [system.collections.arraylist]@()
                $fileNameFile = Get-FileName
                $fileNameFileImport = import-csv $filenamefile
                foreach($file in $filenamefileimport){$filenames.Add($file.filename) | Out-Null}
                Write-host "Starting File Search Jobs"
                <#
                    OK how the fuck am i gonna do this 
                #> 
                foreach($i in (Get-PSSession)){
                     (Invoke-Command -session $i -ScriptBlock{
                        $files = $using:filenames;
                        cd C:\Users;
                        Get-ChildItem -Recurse | ?{$files.Contains($_.name)}         
                     }  -asjob -jobname "FindFile")| out-null         
                }Create-Artifact
                break
            }elseif($findfile -ieq 'n'){
                return $false
            }else{
                Write-host "Not a valid option"
            }
           }while($true)
       }
}

function Retry-FailedJobs{}

function TearDown-Sessions{
    if(!$localBox){
        do{
            $sessions = Read-Host "Do you want to tear down the PSSessions?(y/n)"

            if($sessions -ieq 'y'){
                Remove-PSSession * | out-null
                return $true
            }elseif($sessions -ieq 'n'){
                return $false
            }
            else{
                Write-Host "Not a valid option"
            }
        }while($true)
    }
}


function Build-Sessions{
    if(!$localBox){
        <#
            Clean up and broken PSSessions.
        #>
        $brokenSessions = (Get-PSSession | ?{$_.State -eq "Broken"}).Id
        if($brokenSessions -ne $null){
            Remove-PSSession -id $brokenSessions
        }
        $activeSessions = (Get-PSSession | ?{$_.State -eq "Opened"}).ComputerName

        <#
            Create PSSessions
        #>
        foreach($i in $nodeList){
            if($activeSessions -ne $null){
                if(!$activeSessions.Contains($i.hostname)){
                    if(($i.hostname -ne "") -and ($i.operatingsystem -like "*Windows*")){
                        Write-host "Starting PSSession on" $i.hostname
                        New-pssession -computername $i.hostname -name $i.hostname -SessionOption (New-PSSessionOption -NoMachineProfile -MaxConnectionRetryCount 5) -ThrottleLimit 100| out-null
                    }
                }else{
                    Write-host "PSSession already exists:" $i.hostname -ForegroundColor Red
                }
            }else{
                if(($i.hostname -ne "") -and ($i.operatingsystem -like "*windows*")){
                    Write-host "Starting PSSession on" $i.hostname
                    New-pssession -computername $i.hostname -name $i.hostname -SessionOption (New-PSSessionOption -NoMachineProfile -MaxConnectionRetryCount 5) -ThrottleLimit 100| out-null
                }
            }
        }
        
    
        if((Get-PSSession | measure).count -eq 0){
            return
        }    

        write-host -ForegroundColor Green "There are" ((Get-PSSession | measure).count) "Sessions."
    } 

}

function WaitFor-Jobs{
    if((get-job | where state -eq "Running" |measure).Count -ne 0){
            write-host -ForegroundColor Green "There are" ((Get-job |?{$_.state -like "*Run*"} | measure).count) "jobs still running."
        do{
            $waitForJobs = Read-Host "Do you want to wait for more of these jobs to finish?(y/n)"

            if($waitForJobs -ieq 'n'){
                Get-job | Remove-Job -Force
                break
            }elseif($waitForJobs -ieq 'y'){
                $runningJobThreshold--
                Create-Artifact
                #break
            }else{
                Write-Host "Not a valid option"
            }
            
        }while($true)            

    }

}

function VisibleWirelessNetworks{
    Write-host "Starting VisibleWirelessNetwork Jobs"
    if($localBox){
        $netshresults = (netsh wlan show networks mode=bssid);
                $networksarraylist = [System.Collections.ArrayList]@();
                if((($netshresults.gettype()).basetype.name -eq "Array") -and ($netshresults.count -gt 10)){
                    for($i = 4; $i -lt ($netshresults.Length); $i+=11){
                        $WLANobject = [PSCustomObject]@{
                            SSID = ""
                            NetworkType = ""
                            Authentication = ""
                            Encryption = ""
                            BSSID = ""
                            SignalPercentage = ""
                            RadioType = ""
                            Channel = ""
                            BasicRates = ""
                            OtherRates = ""
                        }
                        for($j=0;$j -lt 10;$j++){
                            $currentline = $netshresults[$i + $j]
                            if($currentline -like "SSID*"){
                                $currentline = $currentline.substring(9)
                                if($currentline.startswith(" ")){

                                    $currentline = $currentline.substring(1)
                                    $WLANobject.SSID = $currentline

                                }else{

                                    $WLANobject.SSID = $currentline

                                }

                            }elseif($currentline -like "*Network type*"){

                                $WLANobject.NetworkType = $currentline.Substring(30)

                            }elseif($currentline -like "*Authentication*"){

                                $WLANobject.Authentication = $currentline.Substring(30)

                            }elseif($currentline -like "*Encryption*"){

                                $WLANobject.Encryption = $currentline.Substring(30)

                            }elseif($currentline -like "*BSSID 1*"){

                                $WLANobject.BSSID = $currentline.Substring(30)

                            }elseif($currentline -like "*Signal*"){

                                $WLANobject.SignalPercentage = $currentline.Substring(30)

                            }elseif($currentline -like "*Radio type*"){
        
                                $WLANobject.RadioType = $currentline.Substring(30)
        
                            }elseif($currentline -like "*Channel*"){
            
                                $WLANobject.Channel = $currentline.Substring(30)
                            }elseif($currentline -like "*Basic rates*"){
        
                                $WLANobject.BasicRates = $currentline.Substring(30)

                            }elseif($currentline -like "*Other rates*"){
            
                                $WLANobject.OtherRates = $currentline.Substring(30)

                            }
                        }

                        $networksarraylist.Add($WLANobject) | Out-Null
                    }
                    $networksarraylist | Export-Csv -NoTypeInformation -Append "$outFolder\Local VisibleWirelessNetworks.csv" | out-null
                }
    }else{
        foreach($i in (Get-PSSession)){
            (Invoke-Command -session $i -ScriptBlock{
                $netshresults = (netsh wlan show networks mode=bssid);
                $networksarraylist = [System.Collections.ArrayList]@();
                if((($netshresults.gettype()).basetype.name -eq "Array") -and ($netshresults.count -gt 10)){
                    for($i = 4; $i -lt ($netshresults.Length); $i+=11){
                        $WLANobject = [PSCustomObject]@{
                            SSID = ""
                            NetworkType = ""
                            Authentication = ""
                            Encryption = ""
                            BSSID = ""
                            SignalPercentage = ""
                            RadioType = ""
                            Channel = ""
                            BasicRates = ""
                            OtherRates = ""
                        }
                        for($j=0;$j -lt 10;$j++){
                            $currentline = $netshresults[$i + $j]
                            if($currentline -like "SSID*"){
                                $currentline = $currentline.substring(9)
                                if($currentline.startswith(" ")){

                                    $currentline = $currentline.substring(1)
                                    $WLANobject.SSID = $currentline

                                }else{

                                    $WLANobject.SSID = $currentline

                                }

                            }elseif($currentline -like "*Network type*"){

                                $WLANobject.NetworkType = $currentline.Substring(30)

                            }elseif($currentline -like "*Authentication*"){

                                $WLANobject.Authentication = $currentline.Substring(30)

                            }elseif($currentline -like "*Encryption*"){

                                $WLANobject.Encryption = $currentline.Substring(30)

                            }elseif($currentline -like "*BSSID 1*"){

                                $WLANobject.BSSID = $currentline.Substring(30)

                            }elseif($currentline -like "*Signal*"){

                                $WLANobject.SignalPercentage = $currentline.Substring(30)

                            }elseif($currentline -like "*Radio type*"){
        
                                $WLANobject.RadioType = $currentline.Substring(30)
        
                            }elseif($currentline -like "*Channel*"){
            
                                $WLANobject.Channel = $currentline.Substring(30)
                            }elseif($currentline -like "*Basic rates*"){
        
                                $WLANobject.BasicRates = $currentline.Substring(30)

                            }elseif($currentline -like "*Other rates*"){
            
                                $WLANobject.OtherRates = $currentline.Substring(30)

                            }
                        }

                        $networksarraylist.Add($WLANobject) | Out-Null
                    }
                    $networksarraylist
                }
                                 
            }  -asjob -jobname "VisibleWirelessNetworks")
        }
        Create-Artifact
    }

}

function HistoricalWiFiConnections{
    Write-host "Starting HistoricalWiFiConnections Jobs"
    if($localBox){
        $netshresults = (netsh wlan show profiles);
                $networksarraylist = [System.Collections.ArrayList]@();
                if((($netshresults.gettype()).basetype.name -eq "Array") -and (!($netshresults[9].contains("<None>")))){
                    for($i = 9;$i -lt ($netshresults.Length -1);$i++){
                        $WLANProfileObject = [PSCustomObject]@{
                            ProfileName = ""
                            Type = ""
                            ConnectionMode = ""
                        }
                        $WLANProfileObject.profilename = $netshresults[$i].Substring(27)
                        $networksarraylist.Add($WLANProfileObject) | out-null
                        $individualProfile = (netsh wlan show profiles name="$($WLANProfileObject.ProfileName)")
                        $WLANProfileObject.type = $individualProfile[9].Substring(29)
                        $WLANProfileObject.connectionmode = $individualProfile[12].substring(29)
                    }
                }
                $networksarraylist | Export-Csv -NoTypeInformation -Append "$outFolder\Local HistoricalWiFiConnections.csv" | out-null
    }else{
        foreach($i in (Get-PSSession)){
            (Invoke-Command -session $i -ScriptBlock{
                $netshresults = (netsh wlan show profiles);
                $networksarraylist = [System.Collections.ArrayList]@();
                if((($netshresults.gettype()).basetype.name -eq "Array") -and (!($netshresults[9].contains("<None>")))){
                    for($i = 9;$i -lt ($netshresults.Length -1);$i++){
                        $WLANProfileObject = [PSCustomObject]@{
                            ProfileName = ""
                            Type = ""
                            ConnectionMode = ""
                        }
                        $WLANProfileObject.profilename = $netshresults[$i].Substring(27)
                        $networksarraylist.Add($WLANProfileObject) | out-null
                        $individualProfile = (netsh wlan show profiles name="$($WLANProfileObject.ProfileName)")
                        $WLANProfileObject.type = $individualProfile[9].Substring(29)
                        $WLANProfileObject.connectionmode = $individualProfile[12].substring(29)
                    }
                }
                $networksarraylist
            
            } -AsJob -JobName "HistoricalWiFiConnections")
        }
        Create-Artifact
    }
}

function Enable-PSRemoting{
    
    foreach($node in $nodeList){
        wmic /node:$($node.IpAddress) process call create "powershell enable-psremoting -force"
    }
}

function HistoricalFirewallChanges{
    
    Write-host "Starting HistoricalFirewallChanges Jobs"
    if($localBox){
        Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Firewall With Advanced Security/Firewall';} | select timecreated,message | export-csv -NoTypeInformation -Append "$outFolder\Local HistoricalFirewallChanges.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Firewall With Advanced Security/Firewall';} | select TimeCreated, Message}  -asjob -jobname "HistoricalFirewallChanges") | out-null
        }
        Create-Artifact
    }

}

function CapabilityAccessManager{
    
    Write-host "Starting CapabilityAccessManager Jobs"
    if($localBox){
        (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\*\NonPackaged\*) | export-csv -NoTypeInformation -Append "$outFolder\Local CapabilityAccessManager.csv" | Out-Null
    }else{    
        foreach($i in (Get-PSSession)){           
            (Invoke-Command -session $i -ScriptBlock  {(Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\*\NonPackaged\*)}  -asjob -jobname "CapabilityAccessManager") | out-null
        }
        Create-Artifact
    }

}

function Meta-Blue {    
    <#
        This is the data gathering portion of this script. PSSessions are created on all live windows
        boxes. In order to create a new query, copy and paste and existing one. Change the write-host
        output to reflect the query's actions as well as the jobname parameter. Every 3rd query or so,
        add a call to Create-Artifact. This really impacts machines with small amounts of RAM.
    #>
    Build-Sessions
        
    <#
        Begining the artifact collection. Will start one job per session and then wait for all jobs
        of that type to complete before moving on to the next set of jobs.
    #>
    Write-host -ForegroundColor Green "[+]Begin Artifact Gathering"  
    Write-Host -ForegroundColor Yellow "[+]Sometimes the Powershell window needs you to click on it and press enter"
    Write-Host -ForegroundColor Yellow "[+]If it doesn't move on for a while, give it a try!"
    Write-Host -ForegroundColor Yellow "[+]Someone figure out how to make this not happen and I will give you a cookie" 
    
    ArpCache
    DLLSearchOrderHijacking
    StartupFolder
    WebShell    
    UnsignedDrivers
    VisibleWirelessNetworks
    HistoricalWiFiConnections
    PoshVersion
    Registry
    SMBConns
    WMIEventFilters
    LogonScripts
    WMIEventConsumers
    NetshHelperDLL
    WMIEventConsumerBinds
    LogicalDisks
    KnownDLLs
    DiskDrives
    SystemInfo
    SMBShares
    SystemFirmware
    AVProduct
    PortMonitors
    Startup
    Hotfix
    NetAdapters
    AccessibilityFeature
    DNSCache
    Logons
    LSASSDriver
    ProcessHash
    AlternateDataStreams
    NetConns
    EnvironVars
    DriverHash
    SchedTasks
    PNPDevices 
    InstalledSoftware
    PrefetchListing
    Processes
    Services
    DLLHash
    Drivers
    BITSJobs
    HistoricalFirewallChanges
    CapabilityAccessManager
    #ProgramData
    DLLs
    #Update-Sysmon
    #Find-File
    TearDown-Sessions
    WaitFor-Jobs
    Shipto-Splunk
    cd $Home\desktop
         
}

function Show-TitleMenu{
     cls
     Write-Host "================META-BLUE================"
    
     Write-Host "1: Press '1' to run Meta-Blue as enumeration only."
     Write-Host "2: Press '2' to run Meta-Blue as both enumeration and artifact collection."
     Write-Host "3: Press '3' to audit snort rules."
     Write-Host "4: Press '4' to remotely perform dump."
     Write-Host "5: Press '5' to run Meta-Blue against the local box."
     Write-Host "Q: Press 'Q' to quit."
    
    $input = Read-Host "Please make a selection (title)"
     switch ($input)
     {
           '1' {
                cls
                show-EnumMenu
                break
           } '2' {
                cls
                Show-CollectionMenu
                break
           } '3' {
                cls                
                Audit-Snort
                break    
           } '4'{
                cls
                Show-MemoryDumpMenu
                break
           
           }'5'{
                $localBox = $true
                Meta-Blue
                break
           
            }
            'q' {
                break 
           } 

     }break
    
}

function Show-EnumMenu{
     
     cls
     Write-Host "================META-BLUE================"
     Write-Host "============Enumeration Only ================"
     Write-Host "      Do you have a list of hosts?"
     Write-Host "1: Yes"
     Write-Host "2: No"
     Write-Host "3: Return to previous menu."
     Write-Host "Q: Press 'Q' to quit."

                do{
                $input = Read-Host "Please make a selection(enum)"
                switch ($input)
                {
                    '1' {
                            $PTL = [System.Collections.arraylist]@()
                            $ptlFile = get-filename                        
                            if($ptlFile -eq ""){
                                Write-warning "Not a valid path!"
                                pause
                                show-enummenu
                            }
                            if($ptlFile -like "*.csv"){
                                $ptlimport = import-csv $ptlFile
                                foreach($ip in $ptlimport){$PTL.Add($ip.ipaddress) | out-null}
                                Enumerator($PTL)
                            }if($ptlFile -like "*.txt"){
                                $PTL = Get-Content $ptlFile
                                Enumerator($PTL)
                            }
                            break
                        }
                    '2'{
                            Write-Host "Running the default scan"
                            $subnets = Read-Host "How many seperate subnets do you want to scan?"

                            $ips = @()

                            for($i = 0; $i -lt $subnets; $i++){
                                $ipa = Read-Host "[$($i +1)]Please enter the network id to scan"
                                $cidr = Read-Host "[$($i +1)]Please enter the CIDR"
                                $ips += Get-SubnetRange -IPAddress $ipa -CIDR $cidr
                            }
                            Enumerator($ips)
                            break
                        }
                    '3'{
                            Show-TitleMenu
                            break
                    }
                    'q' {
                            break
                        }
                }
            }until ($input -eq 'q')
}

function Show-CollectionMenu{
    cls
     Write-Host "================META-BLUE================"
     Write-Host "============Artifact Collection ================"
     Write-Host "          Please Make a Selection               "
     Write-Host "1: Collect from a list of hosts"
     Write-Host "2: Collect from a network enumeration"
     Write-Host "3: Collect from active directory list (RSAT required!!)"
     Write-Host "4: Return to Previous menu."
     Write-Host "Q: Press 'Q' to quit."

                do{
                $input = Read-Host "Please make a selection(collection)"
                switch ($input)
                {
                    '1' {
                            $PTL = [System.Collections.arraylist]@()
                            $ptlFile = get-filename                        
                            if($ptlFile -eq ""){
                                Write-warning "Not a valid path!"
                                pause
                                show-enummenu
                            }
                            if($ptlFile -like "*.csv"){
                                $ptlimport = import-csv $ptlFile
                                foreach($ip in $ptlimport){$PTL.Add($ip.ipaddress) | out-null}
                                Enumerator($PTL)
                            }if($ptlFile -like "*.txt"){
                                $PTL = Get-Content $ptlFile
                                Enumerator($PTL)
                            }
                            Meta-Blue
                            break
                        }
                    '2'{
                            Write-Host "Running the default scan"
                            $subnets = Read-Host "How many seperate subnets do you want to scan?"

                            $ips = @()

                            for($i = 0; $i -lt $subnets; $i++){
                                $ipa = Read-Host "[$($i +1)]Please enter the network id to scan"
                                $cidr = Read-Host "[$($i +1)]Please enter the CIDR"
                                $ips += Get-SubnetRange -IPAddress $ipa -CIDR $cidr
                            }
                            Enumerator($ips)
                            Meta-Blue
                            break
                        }
                    '3'{
                            $adEnumeration = $true
                            $iparray = (Get-ADComputer -filter *).dnshostname
                            Enumerator($iparray)
                            Meta-Blue
                            break                           
                    
                        }
                    '4'{
                            Show-TitleMenu
                            break
                    }
                    'q' {
                  
                            break
                        }
                }
            }until ($input -eq 'q')
}

function Show-MemoryDumpMenu{   
    do{
        cls
        Write-Host "================META-BLUE================"
        Write-Host "============Memory Dump ================"
        Write-Host "      Do you have a list of hosts?"
        Write-Host "1: Yes"
        Write-Host "2: Return to previous menu."
        Write-Host "Q: Press 'Q' to quit."
        $input = Read-Host "Please make a selection(dump)"
        switch ($input)
        {
            '1' {
                    $hostsToDump = [System.Collections.arraylist]@()
                    $hostsToDumpFile = get-filename                        
                    if($hostsToDumpFile -eq ""){
                        Write-warning "Not a valid path!"
                        pause
                        }else{
                        $dumpImport = import-csv $hostsToDumpFile
                        foreach($ip in $dumpImport){$hostsToDump.Add($ip.ipaddress) | out-null}
                        Enumerator($hostsToDump)
                        Memory-Dumper
                        break
                    }
                }
            '2'{
                    Show-TitleMenu
                    break
                }
            'q' {
                    break
                }
        }
    }until ($input -eq 'q')
}

show-titlemenu
