# Package

version       = "0.1.1"
author        = "Emery Hemingway"
description   = "A simple content addressed file-system"
license       = "GPLv3"
srcDir        = "src"

requires "nim >= 0.18.0", "base58", "cbor >= 0.2.0"

bin = @["dagfs_repl.nim"]
skipFiles = @["dagfs_repl.nim"]
