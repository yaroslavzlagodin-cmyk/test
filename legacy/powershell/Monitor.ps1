param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$collector=Join-Path $PSScriptRoot 'Collect.ps1'
$layout=[xml](Get-Content (Join-Path $PSScriptRoot 'Dashboard.xaml') -Raw -Encoding UTF8)
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
foreach ($name in 'cards','machine','graphTitle','scale','plot','processTab','eventTab','searchPanel','search','processGrid','eventGrid','status') {
    Set-Variable $name ($window.FindName($name))
}
$machine.Text=$env:COMPUTERNAME
$titles='Процесор','Оперативна пам’ять',("Диск "+$env:SystemDrive),'Мережа'
$keys='Cpu','Memory','Disk','Network'
$colors='#79DFBB','#ACB3FF','#F0BB81','#75D0F3'
$values=@(); $details=@(); $buttons=@()
$history=[Collections.Generic.List[object]]::new()
$selected=0
$latest=$null
$showEvents=$false
$sampleStatus='Зчитування показників…'
$eventStatus='Зчитування журналу System…'
function Draw-Graph {
    $plot.Children.Clear()
    $key=$keys[$selected]
    $graphTitle.Text=$titles[$selected]
    $maximum=100
    if ($key -eq 'Network') {
        $maximum=[math]::Max(1,[double](($history | Measure-Object Network -Maximum).Maximum))
        $scale.Text='0–{0:N1} КіБ/с' -f $maximum
    } else {$scale.Text='0–100 %'}
    foreach ($y in 8,45,82) {
        $line=[Windows.Shapes.Line]::new()
        $line.X2=$plot.ActualWidth; $line.Y1=$y; $line.Y2=$y; $line.Stroke='#2C3C49'
        [void]$plot.Children.Add($line)
    }
    if (!$history.Count) {return}
    $end=$history[$history.Count-1].Time
    $curve=$null; $previous=$null
    foreach ($s in $history) {
        # Після пропуску вимірювань починаємо окрему лінію.
        if ($null -eq $s.$key) {$curve=$null; continue}
        if (!$curve -or ($s.Time-$previous).TotalSeconds -gt 8) {
            $curve=[Windows.Shapes.Polyline]::new()
            $curve.Stroke=$colors[$selected]; $curve.StrokeThickness=2.3
            [void]$plot.Children.Add($curve)
        }
        $x=(1-($end-$s.Time).TotalSeconds/60)*$plot.ActualWidth
        $curve.Points.Add([Windows.Point]::new($x,82-74*[math]::Min(1,$s.$key/$maximum)))
        $previous=$s.Time
    }
}
function Select-Metric([int]$index) {
    $script:selected=$index
    for ($j=0;$j -lt $buttons.Count;$j++) {
        $buttons[$j].Background=if ($j -eq $index) {'#2A414A'} else {'#192630'}
    }
    Draw-Graph
}
for ($i=0;$i -lt 4;$i++) {
    $b=[Windows.Controls.Button]::new(); $b.Tag=$i
    $stack=[Windows.Controls.StackPanel]::new()
    foreach ($part in 'title','value','detail') {
        $t=[Windows.Controls.TextBlock]::new()
        switch ($part) {
            title {$t.Text=$titles[$i]; $t.FontSize=14}
            value {$t.Text='—'; $t.FontSize=28; $t.Foreground=$colors[$i]; $values+=$t}
            detail {$t.Text='Зчитування…'; $t.Foreground='#ACBFCC'; $details+=$t}
        }
        [void]$stack.Children.Add($t)
    }
    $b.Content=$stack; $buttons+=$b
    [void]$cards.Children.Add($b)
    $b.Add_Click({param($sender,$e) Select-Metric $sender.Tag})
}
function Filter-Processes {
    if (!$latest) {return}
    $q=$search.Text.Trim()
    $processGrid.ItemsSource=@($latest.Rows | Where-Object {
        !$q -or $_.Name.IndexOf($q,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or [string]$_.Id -eq $q
    })
}
function Select-Tab([bool]$events) {
    $script:showEvents=$events
    $processGrid.Visibility=if ($events) {'Collapsed'} else {'Visible'}
    $eventGrid.Visibility=if ($events) {'Visible'} else {'Collapsed'}
    $searchPanel.Visibility=$processGrid.Visibility
    $processTab.Background=if ($events) {'#21313E'} else {'#245B50'}
    $eventTab.Background=if ($events) {'#245B50'} else {'#21313E'}
    $status.Text=if ($events) {$eventStatus} else {$sampleStatus}
}
function Show-Sample($s) {
    $script:latest=$s
    $history.Add(($s | Select-Object Time,Cpu,Memory,Disk,Network))
    while (($s.Time-$history[0].Time).TotalSeconds -gt 60) {$history.RemoveAt(0)}
    for ($i=0;$i -lt 4;$i++) {
        $value=$s.($keys[$i])
        $values[$i].Text=if ($null -eq $value) {'—'} elseif ($i -eq 3) {'{0:N1}' -f $value} else {'{0:N1} %' -f $value}
    }
    $details[0].Text='Навантаження'
    $details[1].Text='{0:N1} з {1:N1} ГіБ' -f $s.RamUsed,$s.RamTotal
    $details[2].Text=if ($null -ne $s.Disk) {'Вільно {0:N1} ГіБ' -f $s.DiskFree} else {'Дані недоступні'}
    $details[3].Text='КіБ/с · прийом і передача'
    $script:sampleStatus='Оновлено {0:HH:mm:ss}   ·   Процесів: {1}   ·   Запуск Windows: {2:dd.MM.yyyy HH:mm}' -f $s.Time,$s.Rows.Count,$s.Boot
    Filter-Processes
    Draw-Graph
}
$jobs=@{}
function Start-Read($key,$command) {
    # Окремий runspace читає системні дані. Лише потік WPF змінює елементи вікна.
    $worker=[PowerShell]::Create()
    [void]$worker.AddScript('param($file,$command) . $file; & $command').AddArgument($collector).AddArgument($command)
    $jobs[$key]=@{Worker=$worker; Handle=$worker.BeginInvoke()}
}
$nextSample=$nextEvents=[datetime]::MinValue
function Update-Dashboard {
    foreach ($key in @($jobs.Keys)) {
        $job=$jobs[$key]
        if (!$job.Handle.IsCompleted) {continue}
        try {
            $result=$job.Worker.EndInvoke($job.Handle)
            if ($key -eq 'sample') {
                if (!$result.Count) {throw 'Системні дані недоступні'}
                Show-Sample $result[0]
            } else {
                if ($job.Worker.Streams.Error.Count) {throw $job.Worker.Streams.Error[0]}
                $eventGrid.ItemsSource=@($result | ForEach-Object {$_})
                $script:eventStatus="Записів у журналі System: $($result.Count) · До 200 останніх подій"
            }
        } catch {
            if ($key -eq 'sample') {$script:sampleStatus="Помилка оновлення. $($_.Exception.Message)"} else {$script:eventStatus="Журнал недоступний. $($_.Exception.Message)"}
        } finally {$job.Worker.Dispose(); $jobs.Remove($key)}
    }
    $now=Get-Date
    if (!$jobs.sample -and $now -ge $nextSample) {Start-Read sample Get-PulseSample; $script:nextSample=$now.AddSeconds(2)}
    if (!$jobs.events -and $now -ge $nextEvents) {Start-Read events Get-PulseEvents; $script:nextEvents=$now.AddMinutes(1)}
    $status.Text=if ($showEvents) {$eventStatus} else {$sampleStatus}
}
$processTab.Add_Click({Select-Tab $false}); $eventTab.Add_Click({Select-Tab $true})
$search.Add_TextChanged({Filter-Processes}); $plot.Add_SizeChanged({Draw-Graph})
Select-Tab $false
Select-Metric 0
$timer=[Windows.Threading.DispatcherTimer]::new()
$timer.Interval=[timespan]::FromMilliseconds(350)
$timer.Add_Tick({Update-Dashboard})
try {
    if ($SelfTest) {
        Update-Dashboard
        $deadline=(Get-Date).AddSeconds(40)
        do {Start-Sleep -Milliseconds 150; Update-Dashboard} until (($latest -and $eventStatus -ne 'Зчитування журналу System…') -or (Get-Date) -gt $deadline)
        if (!$latest -or !$processGrid.Items.Count) {throw $sampleStatus}
        if ($eventStatus -notlike 'Записів*') {throw $eventStatus}
        $search.Text=[string]$latest.Rows[0].Id
        if (!$processGrid.Items.Count) {throw 'Пошук PID'}
        foreach ($i in 0..3) {Select-Metric $i}
        Select-Tab $true
        $window.Measure([Windows.Size]::new(1100,800))
        $window.Arrange([Windows.Rect]::new(0,0,1100,800))
        "OK | $sampleStatus | $eventStatus"
    } else {
        $window.Add_ContentRendered({$timer.Start()})
        [void]$window.ShowDialog()
    }
} finally {
    $timer.Stop()
    foreach ($job in $jobs.Values) {$job.Worker.Dispose()}
}
