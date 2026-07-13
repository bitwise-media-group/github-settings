# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# github-settings — org/repo settings-as-code. Everything lives in mise tasks:
# the markdown-lib archetype (prose + license policy, pinned tools) comes from
# the shared toolchain submodule at .mise/, selected in the root mise.toml.
# This Makefile is only the thin forwarding shim — `make <task>` == `mise run <task>`.
include .mise/mise.mk
