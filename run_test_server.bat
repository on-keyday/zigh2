@echo off
setlocal
set GODEBUG=http2debug=2
go run ./test/server.go
