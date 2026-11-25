# Дані зчитуємо локально. Кожен лічильник може мати власні обмеження доступу.
function Get-PulseSample {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    $processor = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    $net = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue)
    $rows = @(Get-Process | ForEach-Object {
        $start = $null
        # Захищені процеси іноді приховують час запуску.
        try { $start = $_.StartTime } catch {}
        [pscustomobject]@{Name=$_.ProcessName; Id=$_.Id; Memory=[math]::Round($_.WorkingSet64/1MB,1); Started=$start}
    } | Sort-Object Memory -Descending)
    [pscustomobject]@{
        Time=Get-Date; Cpu=$processor.PercentProcessorTime
        Memory=100*(1-$os.FreePhysicalMemory/$os.TotalVisibleMemorySize)
        Disk=if ($drive.Size) {100*(1-$drive.FreeSpace/$drive.Size)}
        Network=if ($net.Count) {($net | Measure-Object BytesTotalPersec -Sum).Sum / 1KB}
        RamUsed=($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1MB
        RamTotal=$os.TotalVisibleMemorySize/1MB; DiskFree=$drive.FreeSpace/1GB
        Boot=$os.LastBootUpTime; Rows=$rows
    }
}
function Get-PulseEvents {
    # Код події має значення в межах конкретного постачальника журналу.
    $xpath = "*[System[(Provider[@Name='Microsoft-Windows-Kernel-General'] and (EventID=12 or EventID=13)) or (Provider[@Name='EventLog'] and EventID=6008) or (Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=41)]]"
    try {
        Get-WinEvent -LogName System -FilterXPath $xpath -MaxEvents 200 -ErrorAction Stop | ForEach-Object {
            $label = switch ($_.Id) {
                12 {'Запуск Windows'} 13 {'Початок вимкнення Windows'}
                41 {'Запуск після некоректного вимкнення'} 6008 {'Виявлено попереднє неочікуване вимкнення'}
            }
            [pscustomobject]@{Time=$_.TimeCreated; Event=$label; Id=$_.Id}
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
    }
}
