#!/bin/sh
# Verification-only native Verilator override; synthesizable RTL is unchanged.
exec /usr/bin/verilator --flatten --trace-depth 1 "$@"
