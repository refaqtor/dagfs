#
# \brief  IPLD session definitions
# \author Emery Hemingway
# \date   2017-11-11
#

#
# Copyright (C) 2017 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import ipld

const MaxPacketSize* = 1 shl 18;

type
  IpldSessionCapability* {.final, pure,
    importcpp: "Ipld::Session_capability",
    header: "<ipld_session/capability.h>".} = object

  IpldPacket* {.
    importcpp: "Ipld::Packet",
    header: "<ipld_session/ipld_session.h>".} = object

  IpldOpcode* {.importcpp: "Ipld::Packet::Opcode".} = enum
    PUT, GET, INVALID

  IpldError* {.importcpp: "Ipld::Packet::Error".} = enum
    OK, MISSING, OVERSIZE, FULL, ERROR

proc size*(pkt: IpldPacket): csize {.importcpp.}
  ## Physical packet size.

proc cidStr(p: IpldPacket): cstring {.importcpp: "#.cid().string()".}
proc cid*(p: IpldPacket): Cid = parseCid $p.cidStr
proc setCid*(p: var IpldPacket; cid: cstring) {.importcpp: "#.cid(@)".}
proc setCid*(p: var IpldPacket; cid: Cid) = p.setCid(cid.toHex())

proc operation*(pkt: IpldPacket): IpldOpcode {.importcpp.}
proc len*(pkt: IpldPacket): csize {.importcpp: "length".}
  ## Logical packet length.
proc setLen*(pkt: var IpldPacket; len: int) {.importcpp: "length".}
  ## Set logical packet length.
proc error*(pkt: IpldPacket): IpldError {.importcpp.}
proc setError*(pkt: var IpldPacket; err: IpldError) {.importcpp: "error".}
