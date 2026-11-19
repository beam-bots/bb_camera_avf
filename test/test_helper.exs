# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

# `:macos` tests need ffmpeg's AVFoundation input, which only exists there.
macos_only = if match?({:unix, :darwin}, :os.type()), do: [], else: [:macos]

ExUnit.start(exclude: [:ffmpeg] ++ macos_only)
