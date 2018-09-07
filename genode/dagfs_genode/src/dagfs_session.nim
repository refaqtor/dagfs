import dagfs

const MaxPacketSize* = 1 shl 18;

type
  DagfsSessionCapability* {.final, pure,
    importcpp: "Dagfs::Session_capability",
    header: "<dagfs_session/capability.h>".} = object

  DagfsPacket* {.
    importcpp: "Dagfs::Packet",
    header: "<dagfs_session/dagfs_session.h>".} = object

  DagfsOpcode* {.importcpp: "Dagfs::Packet::Opcode".} = enum
    PUT, GET, INVALID

  DagfsError* {.importcpp: "Dagfs::Packet::Error".} = enum
    OK, MISSING, OVERSIZE, FULL, ERROR

proc size*(pkt: DagfsPacket): csize {.importcpp.}
  ## Physical packet size.

proc cidStr(p: DagfsPacket): cstring {.importcpp: "#.cid().string()".}
proc cid*(p: DagfsPacket): Cid = parseCid $p.cidStr
proc setCid*(p: var DagfsPacket; cid: cstring) {.importcpp: "#.cid(@)".}
proc setCid*(p: var DagfsPacket; cid: Cid) = p.setCid(cid.toHex())

proc operation*(pkt: DagfsPacket): DagfsOpcode {.importcpp.}
proc len*(pkt: DagfsPacket): csize {.importcpp: "length".}
  ## Logical packet length.
proc setLen*(pkt: var DagfsPacket; len: int) {.importcpp: "length".}
  ## Set logical packet length.
proc error*(pkt: DagfsPacket): DagfsError {.importcpp.}
proc setError*(pkt: var DagfsPacket; err: DagfsError) {.importcpp: "error".}
