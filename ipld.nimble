# Package

version       = "0.1.0"
author        = "Emery Hemingway"
description   = "IPLD library"
license       = "GPLv3"

# Dependencies

requires "nim >= 0.17.3", "nimSHA2", "base58"

bin = @["ipfs_client"]
