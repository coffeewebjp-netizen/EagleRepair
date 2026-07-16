param(
    [string]$Module,
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode = 'Diagnose'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModulesRoot = Join-Path $script:Root 'modules'
$script:Runner = Join-Path $script:Root 'tools\invoke-troubleshooter-module.ps1'
$script:LogRoot = Join-Path $env:LOCALAPPDATA 'CoffeeWeb\TroubleRepair\logs'

function Get-ModuleDefinitions {
    $definitions = New-Object 'System.Collections.Generic.List[object]'
    Get-ChildItem -LiteralPath $script:ModulesRoot -Directory -ErrorAction Stop | ForEach-Object {
        $manifestPath = Join-Path $_.FullName 'module.psd1'
        if (-not (Test-Path -LiteralPath $manifestPath)) { return }
        $data = Import-PowerShellDataFile -LiteralPath $manifestPath
        if (-not $data.Enabled) { return }
        $definitions.Add([PSCustomObject]@{
            Id = [string]$data.Id
            DisplayNameKey = [string]$data.DisplayNameKey
            DescriptionKey = [string]$data.DescriptionKey
            Handler = [string]$data.Handler
            SupportsDiagnose = [bool]$data.SupportsDiagnose
            SupportsRepair = [bool]$data.SupportsRepair
            RepairRequiresAdmin = [bool]$data.RepairRequiresAdmin
            Order = [int]$data.Order
            Directory = $_.FullName
            ManifestPath = $manifestPath
        })
    }
    @($definitions | Sort-Object Order, Id)
}

function Get-ResourceData {
    $path = Join-Path $script:Root 'resources\ja.json'
    [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Get-TextValue([object]$Data, [string]$Path) {
    $value = $Data
    foreach ($part in $Path.Split('.')) {
        $property = $value.PSObject.Properties[$part]
        if (-not $property) { return $Path }
        $value = $property.Value
    }
    [string]$value
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-ProcessArgument([string]$Value) {
    '"' + $Value.Replace('"', '\"') + '"'
}

function New-RunPaths([string]$ModuleId, [string]$RunMode) {
    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    [PSCustomObject]@{
        Log = Join-Path $script:LogRoot (('{0}-{1}-{2}.log' -f $stamp, $ModuleId, $RunMode.ToLowerInvariant()))
        Result = Join-Path $script:LogRoot (('{0}-{1}-{2}.json' -f $stamp, $ModuleId, $RunMode.ToLowerInvariant()))
    }
}

function Get-RunnerArgumentLine([string]$ModuleId, [string]$RunMode, [object]$Paths) {
    @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        '-File ' + (Quote-ProcessArgument $script:Runner)
        '-ModuleId ' + (Quote-ProcessArgument $ModuleId)
        '-Mode ' + (Quote-ProcessArgument $RunMode)
        '-LogPath ' + (Quote-ProcessArgument $Paths.Log)
        '-ResultPath ' + (Quote-ProcessArgument $Paths.Result)
    ) -join ' '
}

$definitions = @(Get-ModuleDefinitions)
if ($Module) {
    $definition = $definitions | Where-Object Id -eq $Module | Select-Object -First 1
    if (-not $definition) {
        throw ('Unknown module: {0}. Available: {1}' -f $Module, (($definitions.Id) -join ', '))
    }
    $paths = New-RunPaths $definition.Id $Mode
    $requiresAdmin = $Mode -eq 'Repair' -and $definition.RepairRequiresAdmin
    $argumentLine = Get-RunnerArgumentLine $definition.Id $Mode $paths
    if ($requiresAdmin -and -not (Test-IsAdministrator)) {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentLine -PassThru
    } else {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
    }
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $paths.Result)) {
        if ($process.HasExited) {
            Start-Sleep -Milliseconds 300
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $paths.Result) {
        $runResult = [IO.File]::ReadAllText($paths.Result, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $exitCode = [int]$runResult.ExitCode
    } elseif ($process.HasExited) {
        $exitCode = $process.ExitCode
    } else {
        $exitCode = 124
    }
    if (Test-Path -LiteralPath $paths.Log) {
        Write-Output ([IO.File]::ReadAllText($paths.Log, [Text.Encoding]::UTF8))
    }
    exit $exitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$text = Get-ResourceData
$form = New-Object Windows.Forms.Form
$form.Text = Get-TextValue $text 'app.title'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(860, 650)
$form.MinimumSize = New-Object Drawing.Size(720, 540)
$form.Font = New-Object Drawing.Font('Yu Gothic UI', 10)

$title = New-Object Windows.Forms.Label
$title.Text = Get-TextValue $text 'app.heading'
$title.Font = New-Object Drawing.Font('Yu Gothic UI', 17, [Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(18, 16)
$form.Controls.Add($title)

$intro = New-Object Windows.Forms.Label
$intro.Text = Get-TextValue $text 'app.intro'
$intro.AutoSize = $true
$intro.Location = New-Object Drawing.Point(21, 54)
$form.Controls.Add($intro)

$modulePanel = New-Object Windows.Forms.FlowLayoutPanel
$modulePanel.Location = New-Object Drawing.Point(18, 83)
$modulePanel.Size = New-Object Drawing.Size(808, 190)
$modulePanel.Anchor = 'Top,Left,Right'
$modulePanel.AutoScroll = $true
$modulePanel.WrapContents = $false
$modulePanel.FlowDirection = 'TopDown'
$form.Controls.Add($modulePanel)

$status = New-Object Windows.Forms.Label
$status.Text = Get-TextValue $text 'status.ready'
$status.AutoSize = $true
$status.Location = New-Object Drawing.Point(21, 283)
$form.Controls.Add($status)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(18, 310)
$logBox.Size = New-Object Drawing.Size(808, 280)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Both'
$logBox.WordWrap = $false
$logBox.Font = New-Object Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

$script:ActionButtons = New-Object 'System.Collections.Generic.List[object]'
$script:CurrentProcess = $null
$script:CurrentPaths = $null
$script:CurrentDefinition = $null
$script:CurrentMode = $null

function Set-ActionsEnabled([bool]$Enabled) {
    foreach ($button in $script:ActionButtons) { $button.Enabled = $Enabled }
}

function Start-ModuleAction([object]$Definition, [string]$RunMode) {
    if ($script:CurrentProcess) { return }
    if ($RunMode -eq 'Repair') {
        $name = Get-TextValue $text $Definition.DisplayNameKey
        $message = (Get-TextValue $text 'dialogs.repairConfirm') -f $name
        $answer = [Windows.Forms.MessageBox]::Show(
            $form,
            $message,
            (Get-TextValue $text 'dialogs.confirmTitle'),
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    $script:CurrentPaths = New-RunPaths $Definition.Id $RunMode
    $script:CurrentDefinition = $Definition
    $script:CurrentMode = $RunMode
    $argumentLine = Get-RunnerArgumentLine $Definition.Id $RunMode $script:CurrentPaths
    $logBox.Clear()
    $status.Text = (Get-TextValue $text 'status.running') -f (Get-TextValue $text $Definition.DisplayNameKey)
    Set-ActionsEnabled $false
    try {
        if ($RunMode -eq 'Repair' -and $Definition.RepairRequiresAdmin) {
            $script:CurrentProcess = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentLine -PassThru
        } else {
            $script:CurrentProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
        }
    } catch {
        $script:CurrentProcess = $null
        Set-ActionsEnabled $true
        $status.Text = Get-TextValue $text 'status.cancelled'
        $logBox.Text = $_.Exception.Message
    }
}

foreach ($definition in $definitions) {
    $group = New-Object Windows.Forms.GroupBox
    $group.Text = Get-TextValue $text $definition.DisplayNameKey
    $group.Size = New-Object Drawing.Size(780, 76)
    $group.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 8)

    $description = New-Object Windows.Forms.Label
    $description.Text = Get-TextValue $text $definition.DescriptionKey
    $description.Location = New-Object Drawing.Point(14, 27)
    $description.Size = New-Object Drawing.Size(520, 36)
    $group.Controls.Add($description)

    $diagnose = New-Object Windows.Forms.Button
    $diagnose.Text = Get-TextValue $text 'buttons.diagnose'
    $diagnose.Location = New-Object Drawing.Point(548, 25)
    $diagnose.Size = New-Object Drawing.Size(96, 32)
    $diagnose.Tag = [PSCustomObject]@{ Definition = $definition; Mode = 'Diagnose' }
    $diagnose.Enabled = $definition.SupportsDiagnose
    $diagnose.Add_Click({ Start-ModuleAction $this.Tag.Definition $this.Tag.Mode })
    $group.Controls.Add($diagnose)
    $script:ActionButtons.Add($diagnose)

    $repair = New-Object Windows.Forms.Button
    $repair.Text = Get-TextValue $text 'buttons.repair'
    $repair.Location = New-Object Drawing.Point(654, 25)
    $repair.Size = New-Object Drawing.Size(108, 32)
    $repair.Tag = [PSCustomObject]@{ Definition = $definition; Mode = 'Repair' }
    $repair.Enabled = $definition.SupportsRepair
    $repair.Add_Click({ Start-ModuleAction $this.Tag.Definition $this.Tag.Mode })
    $group.Controls.Add($repair)
    $script:ActionButtons.Add($repair)

    $modulePanel.Controls.Add($group)
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if (-not $script:CurrentProcess) { return }
    if (Test-Path -LiteralPath $script:CurrentPaths.Log) {
        try {
            $content = [IO.File]::ReadAllText($script:CurrentPaths.Log, [Text.Encoding]::UTF8)
            if ($logBox.Text -ne $content) {
                $logBox.Text = $content
                $logBox.SelectionStart = $logBox.TextLength
                $logBox.ScrollToCaret()
            }
        } catch {}
    }
    if (-not $script:CurrentProcess.HasExited) { return }

    $exitCode = $script:CurrentProcess.ExitCode
    if (Test-Path -LiteralPath $script:CurrentPaths.Result) {
        try {
            $result = [IO.File]::ReadAllText($script:CurrentPaths.Result, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $exitCode = [int]$result.ExitCode
        } catch {}
    }
    if ($exitCode -eq 0) {
        $status.Text = Get-TextValue $text 'status.succeeded'
    } else {
        $status.Text = (Get-TextValue $text 'status.failed') -f $exitCode
    }
    $script:CurrentProcess = $null
    Set-ActionsEnabled $true
})
$timer.Start()

[void]$form.ShowDialog()
