/*
 * \brief  Dagfs C++ session component
 * \author Emery Hemingway
 * \date   2017-11-07
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

#ifndef _INCLUDE__NIM__DAGFS_SERVER_H_
#define _INCLUDE__NIM__DAGFS_SERVER_H_

#include <dagfs_session/rpc_object.h>
#include <base/heap.h>
#include <base/attached_ram_dataspace.h>

struct Communication_buffer
{
	Genode::Attached_ram_dataspace _tx_ds;

	Communication_buffer(Genode::Pd_session &pd,
	                     Genode::Region_map &rm,
	                     Genode::size_t      tx_buf_size)
	: _tx_ds(pd, rm, tx_buf_size) { }
};

struct DagfsSessionComponentBase : Communication_buffer,
                                  Dagfs::Session_rpc_object
{
	static Genode::size_t tx_buf_size(char const *args)
	{
		Genode::size_t const buf_size = Genode::Arg_string::find_arg(
			args, "tx_buf_size").aligned_size();
		if (!buf_size)
			throw Genode::Service_denied();
		return buf_size;
	}

	DagfsSessionComponentBase(Genode::Env *env, char const *args)
	:
		Communication_buffer(env->pd(), env->rm(), tx_buf_size(args)),
		Session_rpc_object(env->rm(), env->ep().rpc_ep(), _tx_ds.cap())
	{ }

	void packetHandler(Genode::Signal_context_capability cap)
	{
		_tx.sigh_ready_to_ack(cap);
		_tx.sigh_packet_avail(cap);
	}
};

#endif /* _INCLUDE__NIM__DAGFS_SERVER_H_ */
