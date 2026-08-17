<#
.SYNOPSIS
    Sweeps every COM port (and optionally several serial settings) sending an EBDS
    omnibus poll, and reports which combination the bill acceptor answers on.

.DESCRIPTION
    Use this when you are not sure which COM port the USB-RS232 adapter enumerated
    as, or whether the unit really is EBDS 9600 7E1. It only ever sends a harmless
    poll with all bill types DISABLED (enable mask 0x00), so nothing can be
    accepted or stacked while scanning.

.EXAMPLE
    .\Find-BillAcceptor.ps1
    .\Find-BillAcceptor.ps1 -AllSettings
    .\Find-BillAcceptor.ps1 -Ports COM4,COM5
#>
[CmdletBinding()]
param(
    [string[]]$Ports,
    [switch]$AllSettings,
    [int]$Attempts = 4,
    [int]$ReplyTimeoutMs = 300
)

$ErrorActionPreference = 'Continue'

function Get-Hex { param([byte[]]$B) ($B | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

function Get-EbdsChecksum {
    param([byte[]]$Bytes)
    $chk = 0
    for ($i = 1; $i -le ($Bytes.Length - 3); $i++) { $chk = $chk -bxor $Bytes[$i] }
    return [byte]($chk -band 0xFF)
}

function New-OmnibusCommand {
    param([int]$Ack)
    # enable mask 0x00 -> accept nothing; data1 0x1C -> escrow mode + all orientations
    $msg = [byte[]](0x02, 0x08, [byte](0x10 -bor $Ack), 0x00, 0x1C, 0x00, 0x03, 0x00)
    $msg[7] = Get-EbdsChecksum -Bytes $msg
    return $msg
}

function Read-EbdsFrame {
    param($Port, [int]$TimeoutMs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $buf = New-Object System.Collections.Generic.List[byte]
    $expected = -1
    while ($sw.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
        if ($Port.BytesToRead -gt 0) {
            $b = $Port.ReadByte()
            if ($buf.Count -eq 0 -and $b -ne 0x02) { continue }
            $buf.Add([byte]$b) | Out-Null
            if ($buf.Count -eq 2) {
                $expected = $buf[1]
                if ($expected -lt 5 -or $expected -gt 250) { $buf.Clear(); $expected = -1 }
            }
            if ($expected -gt 0 -and $buf.Count -ge $expected) { return $buf.ToArray() }
        } else { Start-Sleep -Milliseconds 1 }
    }
    if ($buf.Count -gt 0) { return $buf.ToArray() }
    return $null
}

if (-not $Ports) { $Ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object }
if (-not $Ports) { Write-Host "No COM ports found on this machine." -ForegroundColor Red; exit 1 }

# EBDS is 9600 7E1. The extra rows are only tried with -AllSettings, for the case
# where the unit turns out to be configured differently than expected.
$settings = @(
    @{ Baud = 9600;  Data = 7; Parity = 'Even' }
)
if ($AllSettings) {
    $settings = @(
        @{ Baud = 9600;  Data = 7; Parity = 'Even' },
        @{ Baud = 9600;  Data = 8; Parity = 'None' },
        @{ Baud = 9600;  Data = 8; Parity = 'Even' },
        @{ Baud = 19200; Data = 7; Parity = 'Even' },
        @{ Baud = 19200; Data = 8; Parity = 'None' },
        @{ Baud = 4800;  Data = 7; Parity = 'Even' },
        @{ Baud = 38400; Data = 8; Parity = 'None' }
    )
}

Write-Host ("Scanning ports: {0}" -f ($Ports -join ', ')) -ForegroundColor Cyan
Write-Host ("Settings to try: {0}" -f $settings.Count) -ForegroundColor Cyan
Write-Host ""

$hits = @()

foreach ($p in $Ports) {
    foreach ($s in $settings) {
        $label = "{0} @ {1} {2}{3}1" -f $p, $s.Baud, $s.Data, $s.Parity.Substring(0,1)

        $port = New-Object System.IO.Ports.SerialPort
        $port.PortName  = $p
        $port.BaudRate  = $s.Baud
        $port.DataBits  = $s.Data
        $port.Parity    = [System.IO.Ports.Parity]::($s.Parity)
        $port.StopBits  = [System.IO.Ports.StopBits]::One
        $port.Handshake = [System.IO.Ports.Handshake]::None
        $port.DtrEnable = $true
        $port.RtsEnable = $true
        $port.ReadTimeout = 50
        $port.WriteTimeout = 500

        try { $port.Open() }
        catch {
            Write-Host ("{0,-24} port busy or unavailable ({1})" -f $label, $_.Exception.Message.Split([char]10)[0]) -ForegroundColor DarkGray
            continue
        }

        $got = $null
        $ack = 0
        for ($i = 0; $i -lt $Attempts; $i++) {
            $tx = New-OmnibusCommand -Ack $ack
            $port.DiscardInBuffer()
            try { $port.Write($tx, 0, $tx.Length) } catch { break }
            $rx = Read-EbdsFrame -Port $port -TimeoutMs $ReplyTimeoutMs
            if ($rx) { $got = $rx; break }
            $ack = 1 - $ack
            Start-Sleep -Milliseconds 120
        }

        $port.Close(); $port.Dispose()

        if ($got) {
            $chkOk = ($got.Length -ge 8) -and ((Get-EbdsChecksum -Bytes $got) -eq $got[$got.Length-1])
            $typeOk = ($got.Length -ge 3) -and (($got[2] -band 0xF0) -eq 0x20)
            if ($chkOk -and $typeOk) {
                Write-Host ("{0,-24} *** EBDS ACCEPTOR FOUND ***  {1}" -f $label, (Get-Hex $got)) -ForegroundColor Green
                $hits += [pscustomobject]@{ Port=$p; Baud=$s.Baud; DataBits=$s.Data; Parity=$s.Parity; Reply=(Get-Hex $got); Valid=$true }
            } else {
                Write-Host ("{0,-24} data seen but not valid EBDS: {1}" -f $label, (Get-Hex $got)) -ForegroundColor Yellow
                $hits += [pscustomobject]@{ Port=$p; Baud=$s.Baud; DataBits=$s.Data; Parity=$s.Parity; Reply=(Get-Hex $got); Valid=$false }
            }
        } else {
            Write-Host ("{0,-24} silent" -f $label) -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
$good = $hits | Where-Object { $_.Valid }
if ($good) {
    Write-Host "Acceptor responding on:" -ForegroundColor Green
    $good | Format-Table -AutoSize
    $b = $good[0]
    Write-Host ("Next: .\EBDS-Host.ps1 -PortName {0} -Baud {1} -DataBits {2} -Parity {3} -Seconds 60" -f `
                $b.Port, $b.Baud, $b.DataBits, $b.Parity) -ForegroundColor Cyan
} elseif ($hits) {
    Write-Host "Something replied but it did not parse as EBDS. See the yellow rows above." -ForegroundColor Yellow
} else {
    Write-Host "Nothing responded. Check: 12V power on, harness TX/RX not swapped, correct COM port." -ForegroundColor Red
}
