@echo off
setlocal
chcp 65001 >nul
title Eagle Repair
cd /d %~sdp0

echo.
echo ========================================
echo Eagle Library Repair
echo ========================================
echo.

if /i x%~1==xdiagnose goto diagnose

echo Eagle と Google Drive の状態を確認し、必要な修復を実行します。
echo キャッシュは削除せず、日時付きバックアップへ退避します。
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File %~sdp0tools\eagle-library-repair.ps1 -Repair -RestartDriveFS
set RESULT=%ERRORLEVEL%
goto finished

:diagnose
echo 診断のみ実行します。ファイルやプロセスは変更しません。
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File %~sdp0tools\eagle-library-repair.ps1
set RESULT=%ERRORLEVEL%

:finished
echo.
if %RESULT%==0 (
    echo 完了しました。
) else (
    echo 修復は完了していません。上のエラー内容を確認してください。
    echo 終了コード: %RESULT%
)
echo.
echo この画面は確認後に閉じてください。
if /i x%~2==xnopause exit /b %RESULT%
pause
exit /b %RESULT%
