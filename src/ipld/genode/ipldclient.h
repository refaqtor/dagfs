/*
 * \brief  C++ base of IPLD client
 * \author Emery Hemingway
 * \date   2017-11-08
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

/* Genode includes */
#include <ipld_session/connection.h>
#include <base/heap.h>

struct IpldClientBase
{
	Genode::Heap          heap;
	Genode::Allocator_avl tx_packet_alloc { &heap };
	Ipld::Connection      conn;

	IpldClientBase(Genode::Env *env, char const *label, Genode::size_t tx_buf_size)
	: heap(env->pd(), env->rm()),
      conn(*env, tx_packet_alloc, label, tx_buf_size)
	{ }
};
