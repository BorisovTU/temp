@echo off
set JAVA_HOME="C:\Progra~1\Java\jdk-1.8\"
SET PATH=%PATH%;D:\Users\Loginov-NA\Liquibase

del liquibase_debug.log
echo. > liquibase_debug.log

call D:\Users\Loginov-NA\Liquibase\liquibase --defaultsFile=liquibase_debug.properties --log-level=info --log-file=liquibase_debug.log update
;call liquibase --defaultsFile=liquibase_debug.properties --log-level=info --log-file=liquibase.log update

echo.
echo Press any key to EXIT (the window will close automatically after 5 seconds)
choice /n /t 5 /d N >nul
exit