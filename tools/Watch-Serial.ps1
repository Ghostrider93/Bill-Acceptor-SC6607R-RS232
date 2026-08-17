<#
.SYNOPSIS
    Passive RS232 listener. Hex-dumps everything the device sends, grouped into bursts.

.DESCRIPTION
    Opens a serial port read-only (never transmits) and logs incoming bytes with
    timestamps. Bytes arriving within -GapMs of each other are grouped as one frame,
    which makes packet boundaries obvious.

    Runs for -Seconds then exits on its own (safe for non-interactive shells).

.EXAMPLE
    .\Watch-Serial.ps1 -PortName COM4 -Baud 9600 -Seconds 60
    .\Watch-Serial.ps1 -PortName COM4 -Baud 9600 -Parity Even -LogFile ..\logs\idle.log
#>
[CmdletBinding()]
param(
    [string]$PortName = 'COM1',
    [int]$Baud = 9600,
    [ValidateSet('None','Odd','Even','Mark','Space')]
    [string]$Parity = 'None',
    [int]$DataBits = 8,
    [ValidateSet('One','Two','OnePointFive')]
    [string]$StopBits = 'One',
    [int]$Seconds = 30,
    [string]$LogFile,
    [int]$GapMs = 25,
    [bool]$Dtr = $true,
    [bool]$Rts = $true
)

$ErrorActionPreference = 'Stop'

function Format-HexDump {
    param([byte[]]$Bytes)
    $hex   = ($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    $ascii = -join ($Bytes | ForEach-Object {
        if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' }
    })
    return @{ Hex = $hex; Ascii = $ascii }
}

$lines = New-Object System.Collections.Generic.List[string]
function Emit {
    param([string]$Text)
    Write-Host $Text
    $lines.Add($Text) | Out-Null
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
$port.WriteTimeout = 500

$stopLabel = @{ 'One' = '1'; 'Two' = '2'; 'OnePointFive' = '1.5' }[$StopBits]
Emit ("=== Watch-Serial  {0}  {1} {2}{3}{4}  DTR={5} RTS={6}  for {7}s ===" -f `
      $PortName, $Baud, $DataBits, $Parity.Substring(0,1), $stopLabel, $Dtr, $Rts, $Seconds)

try {
    $port.Open()
} catch {
    Emit ("FAILED to open {0}: {1}" -f $PortName, $_.Exception.Message)
    if ($LogFile) { $lines | Out-File -FilePath $LogFile -Encoding utf8 }
    exit 1
}

$port.DiscardInBuffer()

$sw       = [System.Diagnostics.Stopwatch]::StartNew()
$buffer   = New-Object System.Collections.Generic.List[byte]
$lastByte = $null      # ms timestamp of most recent byte
$frameAt  = $null      # ms timestamp of first byte in current frame
$prevFrame= $null      # ms timestamp of previous frame, for delta column
$total    = 0
$frames   = 0

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {

    $avail = $port.BytesToRead
    if ($avail -gt 0) {
        $chunk = New-Object byte[] $avail
        $got   = $port.Read($chunk, 0, $avail)
        $now   = $sw.Elapsed.TotalMilliseconds
        if ($buffer.Count -eq 0) { $frameAt = $now }
        for ($i = 0; $i -lt $got; $i++) { $buffer.Add($chunk[$i]) | Out-Null }
        $lastByte = $now
        $total += $got
    }
    else {
        Start-Sleep -Milliseconds 2
    }

    # Flush the frame once the line has been quiet for GapMs
    if ($buffer.Count -gt 0 -and ($sw.Elapsed.TotalMilliseconds - $lastByte) -ge $GapMs) {
        $bytes = $buffer.ToArray()
        $dump  = Format-HexDump -Bytes $bytes
        $delta = if ($prevFrame -eq $null) { 0 } else { ($frameAt - $prevFrame) / 1000 }
        Emit ("[{0,8:N3}s] +{1,7:N3}s  {2,3} B  {3}   |{4}|" -f `
              ($frameAt/1000), $delta, $bytes.Length, $dump.Hex, $dump.Ascii)
        $prevFrame = $frameAt
        $frames++
        $buffer.Clear()
    }
}

$port.Close()
$port.Dispose()

Emit ("=== done: {0} bytes in {1} frames over {2}s ===" -f $total, $frames, $Seconds)

if ($LogFile) {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $lines | Out-File -FilePath $LogFile -Encoding utf8
    Write-Host "log written: $LogFile"
}
