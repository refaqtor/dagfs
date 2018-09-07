# Package

version       = "0.1.2"
author        = "Emery Hemingway"
description   = "Dagfs TCP server"
license       = "GPLv3"
srcDir        = "src"
binDir        = "bin"
bin           = @[
  "dagfs_fs",
  "dagfs_fs_store",
  "dagfs_rom",
  "dagfs_server",
  "dagfs_tcp_store"
]
backend       = "cpp"

# Dependencies

requires "nim >= 0.18.1", "dagfs", "genode"

task genode, "Build for Genode":
  exec "nimble build --os:genode -d:posix -d:tcpdebug"
