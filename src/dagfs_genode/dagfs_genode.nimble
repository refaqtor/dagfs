# Package

version       = "0.1.0"
author        = "Emery Hemingway"
description   = "Dagfs TCP server"
license       = "GPLv3"
srcDir        = "src"
bin           = @[
  "dagfs_fs",
  "dagfs_fs_store",
  "dagfs_rom",
  "dagfs_tcp_client",
  "dagfs_tcp_server"
]
backend       = "cpp"

# Dependencies

requires "nim >= 0.18.1", "dagfs", "genode"
