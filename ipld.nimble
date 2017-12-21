# Package

version       = "0.1.1"
author        = "Emery Hemingway"
description   = "IPLD library"
license       = "GPLv3"

# Dependencies

requires "nim >= 0.17.3", "nimSHA2", "base58", "cbor >= 0.2.0"

bin = @["ipldrepl","ipldcat"]
