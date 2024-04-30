@echo off
setlocal
rem for windows error
rm -rf zig-out
zig build -freference-trace
