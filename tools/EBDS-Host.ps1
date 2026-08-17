<#
.SYNOPSIS
    EBDS host (master) for MEI / CPI CashFlow SC-series bill validators over RS232.

.DESCRIPTION
    The acceptor is a SLAVE: it says nothing until polled. This script acts as the
    host, sending the "standard omnibus command" on an interval and decoding the
    acceptor's reply. It prints state transitions and credit events, and can log
    every raw frame for protocol analysis.

    Port settings: 9600 baud, 7 data bits, EVEN parity, 1 stop bit (EBDS standard).

    FRAME FORMAT (verified against captured traffic)
      Host  -> device (8 bytes) : 02 08 1T D0 D1 D2 03 CHK
      Device-> host   (11 bytes): 02 0B 2T D0 D1 D2 D3 D4 D5 03 CHK
        02  = STX
        len = total message length including STX and CHK
        1T  = 0x10 | ACK-toggle   (device echoes the toggle back as 0x20 | T)
        03  = ETX
        CHK = XOR of every byte from LEN up to the last data byte
              (STX and ETX are NOT included -- confirmed by capture)

.EXAMPLE
    # Just watch what the acceptor reports, bills disabled (safe first run)
    .\EBDS-Host.ps1 -PortName COM4 -Seconds 30 -EnableMask 0x00

.EXAMPLE
    # Accept all denominations, auto-stack anything that reaches escrow
    .\EBDS-Host.ps1 -PortName COM4 -Seconds 120 -EnableMask 0x7F -OnEscrow Stack

.EXAMPLE
    # Full raw frame trace to a file
    .\EBDS-Host.ps1 -PortName COM4 -Seconds 60 -ShowRaw -LogFile ..\logs\ebds.log
#>
[CmdletBinding()]
param(
    [string]$PortName = 'COM1',
    [int]$Baud = 9600,
    [ValidateSet('None','Odd','Even','Mark','Space')]
    [string]$Parity = 'Even',
    [int]$DataBits = 7,

    # Bill types 1-7, one bit each. 0x7F = all enabled, 0x00 = accept nothing.
    [int]$EnableMask = 0x7F,

    # What to do when a note reaches escrow.
    [ValidateSet('Stack','Return','Hold')]
    [string]$OnEscrow = 'Stack',

    # Omnibus data byte 1 base value. 0x1C = orientation control bits 2+3 set
    # (accept note in all 4 orientations) plus bit4 = escrow mode enabled.
    [int]$Data1Base = 0x1C,

    # Omnibus data byte 2. 0x00 = plain reporting. Bit4 turns on Extended Note
    # Reporting, which changes the reply format -- leave at 0 unless you want that.
    [int]$Data2 = 0x00,

    [int]$PollMs = 200,
    [int]$ReplyTimeoutMs = 300,
    [int]$Seconds = 60,
    [switch]$ShowRaw,
    [string]$LogFile,

    # Denomination table for bill type index 1-7. Default is the usual US set.
    # VERIFY against your unit's bill set -- this ordering is dataset dependent.
    [string[]]$Denominations = @('$1','$2','$5','$10','$20','$50','$100')
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ----

$script:Lines = New-Object System.Collections.Generic.List[string]

function Emit {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:Lines.Add($Text) | Out-Null
}

# Raw frames always go to the log file; -ShowRaw additionally echoes them to the
# console. Keeps a long capture readable without losing the frame-level detail.
function EmitRaw {
    param([string]$Text)
    if ($ShowRaw) { Write-Host $Text -ForegroundColor DarkGray }
    $script:Lines.Add($Text) | Out-Null
}

function Get-Hex {
    param([byte[]]$Bytes)
    ($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

function Get-EbdsChecksum {
    <# XOR from index 1 (LEN) through the last data byte. STX and ETX excluded. #>
    param([byte[]]$Bytes)
    $chk = 0
    for ($i = 1; $i -le ($Bytes.Length - 3); $i++) { $chk = $chk -bxor $Bytes[$i] }
    return [byte]($chk -band 0xFF)
}

function New-OmnibusCommand {
    param([int]$Ack, [int]$D0, [int]$D1, [int]$D2)
    $msg = New-Object byte[] 8
    $msg[0] = 0x02
    $msg[1] = 0x08
    $msg[2] = [byte](0x10 -bor ($Ack -band 0x01))
    $msg[3] = [byte]($D0 -band 0x7F)
    $msg[4] = [byte]($D1 -band 0x7F)
    $msg[5] = [byte]($D2 -band 0x7F)
    $msg[6] = 0x03
    $msg[7] = Get-EbdsChecksum -Bytes $msg
    return $msg
}

function Read-EbdsFrame {
    <# Resyncs on STX, uses the LEN byte to know how much to read. #>
    param($Port, [int]$TimeoutMs)
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $buf = New-Object System.Collections.Generic.List[byte]
    $expected = -1
    while ($sw.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
        if ($Port.BytesToRead -gt 0) {
            $b = $Port.ReadByte()
            if ($buf.Count -eq 0 -and $b -ne 0x02) { continue }   # hunt for STX
            $buf.Add([byte]$b) | Out-Null
            if ($buf.Count -eq 2) {
                $expected = $buf[1]
                if ($expected -lt 5 -or $expected -gt 250) { $buf.Clear(); $expected = -1 }
            }
            if ($expected -gt 0 -and $buf.Count -ge $expected) { return $buf.ToArray() }
        } else {
            Start-Sleep -Milliseconds 1
        }
    }
    if ($buf.Count -gt 0) { return $buf.ToArray() }
    return $null
}

function Test-Bit { param([int]$Value, [int]$Bit) return (($Value -shr $Bit) -band 1) -eq 1 }

function Get-StatusFlags {
    <#
      Decodes the six data bytes of a standard omnibus reply.
      Bytes 0-2 are well established. Byte 3's bits are lower confidence and are
      reported raw as well, so a trace can confirm them on real hardware.
    #>
    param([byte[]]$D)
    $s = [ordered]@{}

    $s.Idling    = Test-Bit $D[0] 0
    $s.Accepting = Test-Bit $D[0] 1
    $s.Escrowed  = Test-Bit $D[0] 2
    $s.Stacking  = Test-Bit $D[0] 3
    $s.Stacked   = Test-Bit $D[0] 4
    $s.Returning = Test-Bit $D[0] 5
    $s.Returned  = Test-Bit $D[0] 6

    $s.Cheated         = Test-Bit $D[1] 0
    $s.Rejected        = Test-Bit $D[1] 1
    $s.Jammed          = Test-Bit $D[1] 2
    $s.StackerFull     = Test-Bit $D[1] 3
    $s.CassettePresent = Test-Bit $D[1] 4
    $s.Paused          = Test-Bit $D[1] 5
    $s.Calibration     = Test-Bit $D[1] 6

    $s.PowerUp        = Test-Bit $D[2] 0
    $s.InvalidCommand = Test-Bit $D[2] 1
    $s.Failure        = Test-Bit $D[2] 2
    $s.NoteValue      = ($D[2] -shr 3) -band 0x07
    $s.TransportOpen  = Test-Bit $D[2] 6

    $s.Stalled  = Test-Bit $D[3] 0
    $s.Disabled = Test-Bit $D[3] 5

    $s.Model    = $D[4]
    $s.Revision = $D[5]
    return $s
}

function Format-ActiveFlags {
    param($Status)
    $on = @()
    foreach ($k in 'Idling','Accepting','Escrowed','Stacking','Stacked','Returning','Returned',
                   'Cheated','Rejected','Jammed','StackerFull','CassettePresent','Paused',
                   'Calibration','PowerUp','InvalidCommand','Failure','TransportOpen',
                   'Stalled','Disabled') {
        if ($Status.$k) { $on += $k }
    }
    if ($on.Count -eq 0) { return '(none)' }
    return ($on -join ', ')
}

function Get-DenomName {
    param([int]$Index)
    if ($Index -ge 1 -and $Index -le $Denominations.Count) { return $Denominations[$Index-1] }
    return "type$Index"
}

# ------------------------------------------------------------------- main ----

Emit ("=== EBDS host on {0} @ {1} {2}{3}1  enable=0x{4:X2}  onEscrow={5}  for {6}s ===" -f `
      $PortName, $Baud, $DataBits, $Parity.Substring(0,1), $EnableMask, $OnEscrow, $Seconds) 'Cyan'

$port = New-Object System.IO.Ports.SerialPort
$port.PortName  = $PortName
$port.BaudRate  = $Baud
$port.Parity    = [System.IO.Ports.Parity]::$Parity
$port.DataBits  = $DataBits
$port.StopBits  = [System.IO.Ports.StopBits]::One
$port.Handshake = [System.IO.Ports.Handshake]::None
$port.DtrEnable = $true
$port.RtsEnable = $true
$port.ReadTimeout  = 50
$port.WriteTimeout = 500

try { $port.Open() }
catch {
    Emit ("FAILED to open {0}: {1}" -f $PortName, $_.Exception.Message) 'Red'
    exit 1
}
$port.DiscardInBuffer(); $port.DiscardOutBuffer()

$ack        = 0
$pending    = 'None'      # 'Stack' | 'Return' pending for the next poll
$lastFlags  = $null
$polls      = 0
$replies    = 0
$badChk     = 0
$credits    = @()
$sw         = [System.Diagnostics.Stopwatch]::StartNew()

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {

    $d1 = $Data1Base
    if     ($pending -eq 'Stack')  { $d1 = $d1 -bor 0x20 }   # bit5 = stack escrowed note
    elseif ($pending -eq 'Return') { $d1 = $d1 -bor 0x40 }   # bit6 = return escrowed note

    $tx = New-OmnibusCommand -Ack $ack -D0 $EnableMask -D1 $d1 -D2 $Data2
    $port.DiscardInBuffer()
    $port.Write($tx, 0, $tx.Length)
    $polls++
    EmitRaw ("  TX {0}" -f (Get-Hex $tx))

    $rx = Read-EbdsFrame -Port $port -TimeoutMs $ReplyTimeoutMs

    if ($null -eq $rx) {
        if ($polls -eq 1 -or ($polls % 10) -eq 0) {
            Emit ("[{0,6:N1}s] no reply (poll #{1})" -f $sw.Elapsed.TotalSeconds, $polls) 'DarkYellow'
        }
        Start-Sleep -Milliseconds $PollMs
        continue
    }

    EmitRaw ("  RX {0}" -f (Get-Hex $rx))
    $replies++

    # --- validate ---------------------------------------------------------
    if ($rx.Length -lt 8 -or $rx[$rx.Length-2] -ne 0x03) {
        Emit ("[{0,6:N1}s] malformed frame: {1}" -f $sw.Elapsed.TotalSeconds, (Get-Hex $rx)) 'Red'
        Start-Sleep -Milliseconds $PollMs
        continue
    }
    $calc = Get-EbdsChecksum -Bytes $rx
    if ($calc -ne $rx[$rx.Length-1]) {
        $badChk++
        Emit ("[{0,6:N1}s] checksum mismatch (got {1:X2}, calc {2:X2}): {3}" -f `
              $sw.Elapsed.TotalSeconds, $rx[$rx.Length-1], $calc, (Get-Hex $rx)) 'Red'
        Start-Sleep -Milliseconds $PollMs
        continue
    }

    $type = $rx[2]
    if (($type -band 0xF0) -ne 0x20) {
        Emit ("[{0,6:N1}s] non-standard reply type 0x{1:X2}: {2}" -f `
              $sw.Elapsed.TotalSeconds, $type, (Get-Hex $rx)) 'Yellow'
        $ack = 1 - $ack
        Start-Sleep -Milliseconds $PollMs
        continue
    }

    # --- decode -----------------------------------------------------------
    $data   = $rx[3..($rx.Length-3)]
    if ($data.Count -lt 6) {
        Emit ("[{0,6:N1}s] short data field: {1}" -f $sw.Elapsed.TotalSeconds, (Get-Hex $rx)) 'Yellow'
        $ack = 1 - $ack
        Start-Sleep -Milliseconds $PollMs
        continue
    }
    $st    = Get-StatusFlags -D $data
    $flags = Format-ActiveFlags -Status $st

    if ($flags -ne $lastFlags) {
        Emit ("[{0,6:N1}s] {1}   [model 0x{2:X2} rev 0x{3:X2}]" -f `
              $sw.Elapsed.TotalSeconds, $flags, $st.Model, $st.Revision) 'White'
        $lastFlags = $flags
    }

    # --- escrow decision --------------------------------------------------
    if ($st.Escrowed) {
        $denom = Get-DenomName -Index $st.NoteValue
        if ($pending -eq 'None') {
            Emit ("[{0,6:N1}s] ESCROW: note recognised as {1} (type index {2}) -> {3}" -f `
                  $sw.Elapsed.TotalSeconds, $denom, $st.NoteValue, $OnEscrow) 'Yellow'
            if ($OnEscrow -ne 'Hold') { $pending = $OnEscrow }
        }
    } else {
        $pending = 'None'
    }

    if ($st.Stacked -and $st.NoteValue -gt 0) {
        $denom = Get-DenomName -Index $st.NoteValue
        Emit ("[{0,6:N1}s] *** CREDIT: {1} stacked ***" -f $sw.Elapsed.TotalSeconds, $denom) 'Green'
        $credits += $denom
    }
    if ($st.Returned) { Emit ("[{0,6:N1}s] note returned" -f $sw.Elapsed.TotalSeconds) 'Yellow' }
    if ($st.Rejected) { Emit ("[{0,6:N1}s] note rejected (not recognised)" -f $sw.Elapsed.TotalSeconds) 'Yellow' }
    if ($st.Jammed)   { Emit ("[{0,6:N1}s] JAMMED" -f $sw.Elapsed.TotalSeconds) 'Red' }
    if ($st.StackerFull) { Emit ("[{0,6:N1}s] STACKER FULL" -f $sw.Elapsed.TotalSeconds) 'Red' }

    $ack = 1 - $ack
    Start-Sleep -Milliseconds $PollMs
}

$port.Close(); $port.Dispose()

Emit ("=== polls={0} replies={1} badChecksum={2} credits={3} ===" -f `
      $polls, $replies, $badChk, ($(if ($credits.Count) { $credits -join ',' } else { 'none' }))) 'Cyan'

if ($LogFile) {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $script:Lines | Out-File -FilePath $LogFile -Encoding utf8
    Write-Host "log written: $LogFile"
}
