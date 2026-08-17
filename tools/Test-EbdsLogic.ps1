<#
.SYNOPSIS
    Offline self-test of the EBDS framing logic. No hardware required.

    Validates the checksum routine, command builder and status decoder against
    real captured SC-series traffic:
        HOST -> 02 08 10 7F 1C 10 03 6B
        HOST -> 02 08 10 00 10 10 03 18
        DEV  -> 02 0B 20 01 10 00 00 54 2A 03 44
#>

$fails = 0
function Assert-Eq {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL  {0}`n        expected: {1}`n        actual:   {2}" -f $What, $Expected, $Actual) -ForegroundColor Red
        $script:fails++
    }
}

function Get-Hex { param([byte[]]$B) ($B | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

function Get-EbdsChecksum {
    param([byte[]]$Bytes)
    $chk = 0
    for ($i = 1; $i -le ($Bytes.Length - 3); $i++) { $chk = $chk -bxor $Bytes[$i] }
    return [byte]($chk -band 0xFF)
}

function New-OmnibusCommand {
    param([int]$Ack, [int]$D0, [int]$D1, [int]$D2)
    $msg = New-Object byte[] 8
    $msg[0] = 0x02; $msg[1] = 0x08
    $msg[2] = [byte](0x10 -bor ($Ack -band 0x01))
    $msg[3] = [byte]($D0 -band 0x7F)
    $msg[4] = [byte]($D1 -band 0x7F)
    $msg[5] = [byte]($D2 -band 0x7F)
    $msg[6] = 0x03
    $msg[7] = Get-EbdsChecksum -Bytes $msg
    return $msg
}

function Test-Bit { param([int]$Value, [int]$Bit) return (($Value -shr $Bit) -band 1) -eq 1 }

Write-Host "`n-- checksum over captured frames --" -ForegroundColor Cyan

$tx1 = [byte[]](0x02,0x08,0x10,0x7F,0x1C,0x10,0x03,0x6B)
Assert-Eq '6B' ('{0:X2}' -f (Get-EbdsChecksum $tx1)) 'host poll  02 08 10 7F 1C 10 03 -> 6B'

$tx2 = [byte[]](0x02,0x08,0x10,0x00,0x10,0x10,0x03,0x18)
Assert-Eq '18' ('{0:X2}' -f (Get-EbdsChecksum $tx2)) 'host poll  02 08 10 00 10 10 03 -> 18'

$rx1 = [byte[]](0x02,0x0B,0x20,0x01,0x10,0x00,0x00,0x54,0x2A,0x03,0x44)
Assert-Eq '44' ('{0:X2}' -f (Get-EbdsChecksum $rx1)) 'device reply 02 0B 20 01 10 00 00 54 2A 03 -> 44'

Write-Host "`n-- command builder reproduces captured host frames --" -ForegroundColor Cyan
Assert-Eq (Get-Hex $tx1) (Get-Hex (New-OmnibusCommand -Ack 0 -D0 0x7F -D1 0x1C -D2 0x10)) 'rebuild poll #1'
Assert-Eq (Get-Hex $tx2) (Get-Hex (New-OmnibusCommand -Ack 0 -D0 0x00 -D1 0x10 -D2 0x10)) 'rebuild poll #2'

Write-Host "`n-- ACK toggle --" -ForegroundColor Cyan
$a0 = New-OmnibusCommand -Ack 0 -D0 0x7F -D1 0x1C -D2 0x00
$a1 = New-OmnibusCommand -Ack 1 -D0 0x7F -D1 0x1C -D2 0x00
Assert-Eq '10' ('{0:X2}' -f $a0[2]) 'ack=0 gives message type 0x10'
Assert-Eq '11' ('{0:X2}' -f $a1[2]) 'ack=1 gives message type 0x11'
Assert-Eq $true ($a0[7] -ne $a1[7]) 'checksum changes with the ack toggle'

Write-Host "`n-- frame geometry --" -ForegroundColor Cyan
Assert-Eq 8    $tx1[1]              'host LEN byte is 0x08 and matches array length'
Assert-Eq 8    $tx1.Length          'host frame really is 8 bytes'
Assert-Eq 11   $rx1[1]              'device LEN byte is 0x0B'
Assert-Eq 11   $rx1.Length          'device frame really is 11 bytes'
Assert-Eq '03' ('{0:X2}' -f $rx1[$rx1.Length-2]) 'ETX sits at len-2'

Write-Host "`n-- 7-bit cleanliness (all bytes <= 0x7F, consistent with 7E1) --" -ForegroundColor Cyan
$high = @($tx1 + $tx2 + $rx1) | Where-Object { $_ -gt 0x7F }
Assert-Eq 0 $high.Count 'no captured byte exceeds 0x7F'

Write-Host "`n-- status decode of the captured idle reply --" -ForegroundColor Cyan
$d = $rx1[3..8]
Assert-Eq $true  (Test-Bit $d[0] 0) 'Idling set'
Assert-Eq $false (Test-Bit $d[0] 2) 'Escrowed clear'
Assert-Eq $false (Test-Bit $d[0] 4) 'Stacked clear'
Assert-Eq $true  (Test-Bit $d[1] 4) 'CassettePresent set'
Assert-Eq $false (Test-Bit $d[1] 2) 'Jammed clear'
Assert-Eq 0      ((($d[2] -shr 3) -band 0x07)) 'NoteValue = 0 (no note)'
Assert-Eq '54'   ('{0:X2}' -f $d[4]) 'model byte 0x54'
Assert-Eq '2A'   ('{0:X2}' -f $d[5]) 'revision byte 0x2A'

Write-Host "`n-- escrow control bits --" -ForegroundColor Cyan
$stack  = New-OmnibusCommand -Ack 0 -D0 0x7F -D1 (0x1C -bor 0x20) -D2 0x00
$return = New-OmnibusCommand -Ack 0 -D0 0x7F -D1 (0x1C -bor 0x40) -D2 0x00
Assert-Eq '3C' ('{0:X2}' -f $stack[4])  'stack  sets data1 bit5 -> 0x3C'
Assert-Eq '5C' ('{0:X2}' -f $return[4]) 'return sets data1 bit6 -> 0x5C'

Write-Host ""
if ($fails -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host ("$fails TEST(S) FAILED") -ForegroundColor Red; exit 1 }
