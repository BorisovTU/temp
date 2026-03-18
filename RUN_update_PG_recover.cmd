@echo off
set JAVA_HOME="C:\Progra~1\Java\jdk-1.8\"
SET PATH=%PATH%;D:\Users\Loginov-NA\Liquibase

del liquibase_pg_recover.log
echo. > liquibase_pg_recover.log

call D:\Users\Loginov-NA\Liquibase\liquibase --defaultsFile=liquibase_pg_recover.properties --log-level=info --log-file=liquibase_pg_recover.log update

pause