/*
 * \brief  Connection to Dagfs service
 * \author Emery Hemingway
 * \date   2017-11-07
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

#ifndef _INCLUDE__DAGFS_SESSION__CONNECTION_H_
#define _INCLUDE__DAGFS_SESSION__CONNECTION_H_

#include <dagfs_session/client.h>
#include <base/connection.h>
#include <base/allocator.h>

namespace Dagfs {
	struct Connection;
	enum { DEFAULT_GET_BUF_SIZE =  1 << 20 };
}


struct Dagfs::Connection : Genode::Connection<Session>, Session_client
{
	/**
	 * Issue session request
	 *
	 * \noapi
	 */
	Session_capability _session(Genode::Parent &parent,
	                            char const     *label,
	                            Genode::size_t  get_buf_size)
	{
		return session(parent,
		               "ram_quota=%ld, cap_quota=%ld, tx_buf_size=%ld, label=\"%s\"",
		               32*1024*sizeof(long) + get_buf_size,
		               CAP_QUOTA, get_buf_size, label);
	}

	/**
	 * Constructor
	 *
	 * \param tx_buf_size      size of reception buffer in bytes
	 */
	Connection(Genode::Env &env,
	           Genode::Range_allocator &tx_buffer_alloc,
	           char const *label = "",
	           Genode::size_t get_buf_size = DEFAULT_GET_BUF_SIZE)
	:
		Genode::Connection<Session>(
			env, _session(env.parent(), label, get_buf_size)),
		Session_client(cap(), env.rm(), tx_buffer_alloc)
	{ }
};

#endif /* _INCLUDE__DAGFS_SESSION__CONNECTION_H_ */
