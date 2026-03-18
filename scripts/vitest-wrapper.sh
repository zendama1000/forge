#!/bin/bash
# Wrapper script to run vitest via npx
# This ensures the validation command works even when vitest is not in PATH

npx vitest "$@"
