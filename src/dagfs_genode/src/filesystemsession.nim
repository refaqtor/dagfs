#
# \brief  Nim File_system session support
# \author Emery Hemingway
# \date   2017-12-05
#

#
# Copyright (C) 2017 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

const FsH = "<file_system_session/file_system_session.h>"

type
  FsPacket* {.
    header: FsH, importcpp: "File_system::Packet_descriptor".} = object

  Operation* {.
    header: FsH, importcpp: "File_system::Packet_descriptor::Opcode".} = enum
    READ, WRITE, CONTENT_CHANGED, READ_READY, SYNC

proc handle*(pkt: FsPacket): culong {.importcpp: "#.handle().value".}
proc operation*(pkt: FsPacket): Operation {.importcpp.}
proc position*(pkt: FsPacket): BiggestInt {.importcpp.}
proc len*(pkt: FsPacket): int {.importcpp: "length".}
proc setLen*(pkt: FsPacket; n: int) {.importcpp: "length".}
proc succeeded*(pkt: FsPacket): bool {.importcpp.}
proc succeeded*(pkt: FsPacket, b: bool) {.importcpp.}

type
  FsDirentType* {.importcpp: "File_system::Directory_entry::Type".} = enum
    TYPE_FILE, TYPE_DIRECTORY, TYPE_SYMLINK

  FsDirent* {.
    header: FsH, importcpp: "File_system::Directory_entry", final, pure.} = object
    inode* {.importcpp.}: culong
    kind* {.importcpp: "type".}: FsDirentType
    name* {.importcpp.}: cstring

proc fsDirentSize*(): cint {.
  importcpp: "sizeof(File_system::Directory_entry)".}

var MAX_NAME_LEN* {.importcpp:"File_system::MAX_NAME_LEN", noDecl.}: cint
