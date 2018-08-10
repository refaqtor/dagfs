# Package

version       = "0.1.1"
author        = "Emery Hemingway"
description   = "InterPlanetary Linked Data library"
license       = "GPLv3"
srcDir        = "src"

# Dependencies

requires "nim >= 0.18.1", "nimSHA2", "base58", "cbor >= 0.2.0"

bin = @["src/ipld/ipldrepl","src/ipld/ipldcat"]
