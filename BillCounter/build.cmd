@echo off
REM Builds BillCounter.exe using the in-box .NET Framework compiler.
REM Nothing needs installing - csc.exe ships with Windows.

set CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe

"%CSC%" /nologo /target:winexe /optimize+ /codepage:65001 /out:BillCounter.exe ^
  /reference:System.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Windows.Forms.dll ^
  BillCounter.cs

if errorlevel 1 (
  echo.
  echo BUILD FAILED
  exit /b 1
)

echo.
echo Built BillCounter.exe
