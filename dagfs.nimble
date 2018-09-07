# Package

version       = "0.1.2"
author        = "Emery Hemingway"
description   = "A simple content addressed file-system"
license       = "GPLv3"
srcDir        = "src"

requires "nim >= 0.18.0", "base58", "cbor >= 0.5.1"

bin = @["dagfs_repl"]
skipFiles = @["dagfs_repl.nim"]
