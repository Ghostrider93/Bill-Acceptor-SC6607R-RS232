<#
.SYNOPSIS
    Send a hex byte string out the serial port and hex-dump whatever comes back.

.EXAMPLE
    .\Send-Serial.ps1 -PortName COM4 -Baud 9600 -Parity Even -Hex "FC 05 11 03 6C"
    .\Send-Serial.ps1 -PortName COM4 -Hex "02" -Repeat 5 -IntervalMs 200
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Hex,
    [string]$PortName = 'COM1',
    [int]$Baud = 9600,
    [ValidateSet('None','Odd','Even','Mark','Space')]
    [string]$Parity = 'None',
    [int]$DataBits = 8,
    [ValidateSet('One','Two','OnePointFive')]
    [string]$StopBits = 'One',
    [int]$WaitMs = 400,
    [int]$Repeat = 1,
    [int]$IntervalMs = 500,
    [bool]$Dtr = $true,
    [bool]$Rts = $true
)

$ErrorActionPreference = 'Stop'

# Accept "FC 05 11", "FC,05,11", "fc0511", "0xFC 0x05"
$clean = ($Hex -replace '0x','' -replace '[^0-9A-Fa-f]','')
if ($clean.Length % 2 -ne 0) { throw "Hex string has an odd number of nibbles: '$Hex'" }
$tx = New-Object byte[] ($clean.Length / 2)
for ($i = 0; $i -lt $tx.Length; $i++) {
    $tx[$i] = [Convert]::ToByte($clean.Substring($i*2, 2), 16)
}

function Format-HexDump {
    param([byte[]]$Bytes)
    $hex   = ($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $ascii = -join ($Bytes | ForEach-Object {
        if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' } })
    "$hex   |$ascii|"
}

$port = New-Object System.IO.Ports.SerialPort
$port.PortName  = $PortName
$port.BaudRate  = $Baud
$port.Parity    = [System.IO.Ports.Parity]::$Parity
$port.DataBits  = $DataBits
$port.StopBits  = [System.IO.Ports.StopBits]::$StopBits
$port.Handshake = [System.IO.Ports.Handshake]::None
$port.DtrEnable = $Dtr
$port.RtsEnable = $Rts
$port.ReadTimeout  = 50
$port.WriteTimeout = 1000

Write-Host ("=== {0}  {1} {2}{3}{4} ===" -f $PortName, $Baud, $DataBits, $Parity.Substring(0,1), $StopBits)
$port.Open()
$port.DiscardInBuffer()
$port.DiscardOutBuffer()

for ($r = 1; $r -le $Repeat; $r++) {
    $port.DiscardInBuffer()
    $port.Write($tx, 0, $tx.Length)
    Write-Host ("TX[{0}] {1}" -f $r, (Format-HexDump -Bytes $tx))

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rx = New-Object System.Collections.Generic.List[byte]
    $firstAt = $null
    while ($sw.Elapsed.TotalMilliseconds -lt $WaitMs) {
        $avail = $port.BytesToRead
        if ($avail -gt 0) {
            if ($firstAt -eq $null) { $firstAt = $sw.Elapsed.TotalMilliseconds }
            $chunk = New-Object byte[] $avail
            $got = $port.Read($chunk, 0, $avail)
            for ($i = 0; $i -lt $got; $i++) { $rx.Add($chunk[$i]) | Out-Null }
        } else {
            Start-Sleep -Milliseconds 3
        }
    }

    if ($rx.Count -gt 0) {
        Write-Host ("RX[{0}] after {1:N0}ms  {2} B  {3}" -f $r, $firstAt, $rx.Count, (Format-HexDump -Bytes $rx.ToArray())) -ForegroundColor Green
    } else {
        Write-Host ("RX[{0}] <no response in {1}ms>" -f $r, $WaitMs) -ForegroundColor DarkGray
    }

    if ($r -lt $Repeat) { Start-Sleep -Milliseconds $IntervalMs }
}

$port.Close()
$port.Dispose()
