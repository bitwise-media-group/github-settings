# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# github-settings — org/repo settings-as-code. Everything lives in mise tasks:
# the common-only contract (prose + license policy, shell and workflow lint,
# pinned tools) comes from the shared toolchain submodule at .mise/, selected
# in the root mise.toml.
# This Makefile is only the thin forwarding shim — `make <task>` == `mise run <task>`.
include .mise/common/include.mk
