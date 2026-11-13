@echo off
rem tests\args.cmd - dvcl argument passing through cmd (no repo needed). Each line: ARGS <count> :: a | b | ...
rem A literal percent sign through "call" takes four of them in a .cmd (call expands percents once more).
call "%~dp0..\dvcl.cmd" args silo_work Silo pass 2 (Sam): bzn - tower, cornice; (LiDAR mirrors LAS Y). Config: on.
call "%~dp0..\dvcl.cmd" args default "Silo pass 3 (Sam, photos): roof + lantern & dock, 50%%%% off" -y
