@echo off
rem Builds aion2tracker.exe: one static executable (HTML embedded, SQLite compiled in).
rem Requirements: V (https://vlang.io) + MSYS2 UCRT64 gcc, and SQLite amalgamation installed once via:
rem   v run %%VROOT%%\vlib\db\sqlite\install_thirdparty_sqlite.vsh
setlocal
rem put the UCRT64 toolchain first so gcc does not pick up foreign DLLs (git/anaconda mingw)
set "PATH=C:\msys64\ucrt64\bin;%PATH%"
cd /d "%~dp0"
rem vendor\veb is vlib's veb with a fix for request bodies being truncated (uploads hanging);
rem listing it first in -path makes `import veb` use it.
v -prod -cc gcc -cflags -static -path "%~dp0vendor|@vlib|@vmodules" -d veb_max_write_bytes=65536 -d veb_max_read_bytes=65536 -o aion2tracker.exe .
if errorlevel 1 exit /b 1
echo Built aion2tracker.exe
