@echo off
setlocal
set "DEST=%~dp0tools"
if exist "%DEST%" (echo tools already exists. Keep it or rename it before retrying. & exit /b 1)
set "WORK=%TEMP%\ZSir-tools-%RANDOM%-%RANDOM%"
if exist "%WORK%" (echo Temporary directory collision. Please retry. & exit /b 1)
mkdir "%WORK%" || exit /b 1
set "ZIP=%WORK%\ffmpeg.zip"
echo Downloading verified FFmpeg 9.0.2 from gyan.dev. Run once before recording.
if exist "%~dp0ffmpeg.zip" (
copy /Y "%~dp0ffmpeg.zip" "%ZIP%" >nul
) else (
curl.exe --fail --location --retry 2 --connect-timeout 30 --output "%ZIP%" "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip"
)
if errorlevel 1 goto failed
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "if((Get-FileHash -LiteralPath $env:ZIP -Algorithm SHA256).Hash -ne '60F467265B1E312373DBCD92200C2618A74850F98D3D078E94296BB3FA2047BA'){exit 1}"
if errorlevel 1 (echo Checksum verification failed. & goto failed)
tar.exe -xf "%ZIP%" -C "%WORK%"
if errorlevel 1 goto failed
mkdir "%WORK%\tools" || goto failed
copy /Y "%WORK%\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe" "%WORK%\tools\" >nul || goto failed
copy /Y "%WORK%\ffmpeg-9.0.2-essentials_build\bin\ffprobe.exe" "%WORK%\tools\" >nul || goto failed
copy /Y "%WORK%\ffmpeg-9.0.2-essentials_build\LICENSE" "%WORK%\tools\" >nul || goto failed
copy /Y "%WORK%\ffmpeg-9.0.2-essentials_build\README.txt" "%WORK%\tools\" >nul || goto failed
move "%WORK%\tools" "%DEST%" >nul || goto failed
rmdir /s /q "%WORK%"
echo Installed. Open ZSirCapture.Windows.exe to record offline.
if /I not "%~1"=="--no-pause" pause
exit /b 0
:failed
echo Installation failed. No unverified binary will be used.
rmdir /s /q "%WORK%"
exit /b 1
