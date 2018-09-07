/*
 * \brief  C++ File_system session component for Nim
 * \author Emery Hemingway
 * \date   2017-12-02
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

/* Genode includes */
#include <file_system_session/rpc_object.h>
#include <root/component.h>
#include <libc/component.h>
#include <base/heap.h>

typedef unsigned long Handle;

Handle nodeProc(void *state, char *path);
Handle dirProc(void *state, char *path, int create);
Handle fileProc(void *state, Handle dir, char *name, unsigned int mode, int create);
File_system::Status statusProc(void *state, Handle handle);
void closeProc(void *state, Handle handle);
void unlinkProc(void *state, Handle dir, char *name);
void truncateProc(void *state, int file, File_system::file_size_t size);
void moveProc(void *state,
              Handle from_dir, char *from_name,
              Handle to_dir, char *to_name);

namespace File_system { struct SessionComponentBase; }

struct File_system::SessionComponentBase : File_system::Session_rpc_object
{
	void *state;

	SessionComponentBase(Genode::Env *env,
	                     size_t tx_buf_size,
	                     void *state,
	                     Genode::Signal_context_capability cap)
	: Session_rpc_object(env->pd().alloc(tx_buf_size), env->rm(), env->ep().rpc_ep()),
	  state(state)
	{
		_tx.sigh_packet_avail(cap);
		_tx.sigh_ready_to_ack(cap);
	}


	/***********************************
	 ** File_system session interface **
	 ***********************************/

	Node_handle node(File_system::Path const &path) override {
		return Node_handle{ nodeProc(state, path.string()) }; }

	Dir_handle dir(File_system::Path const &path, bool create) override {
		return Dir_handle{ dirProc(state, path.string(), create) }; }

	File_handle file(Dir_handle dir, Name const &name, Mode mode, bool create) override {
		return File_handle{ fileProc(state, dir.value, name.string(), unsigned(mode), create) }; }

	Symlink_handle symlink(Dir_handle, Name const &name, bool create) override {
		throw Lookup_failed(); }

	void close(Node_handle handle) override {
		closeProc(state, handle.value); }

	Status status(Node_handle handle) override {
		return statusProc(state, handle.value); }

	void control(Node_handle h, Control) override { }

	void unlink(Dir_handle dir, Name const &name) override
	{
		if (!unlinkProc)
			throw Permission_denied();
	}

	void truncate(File_handle, File_system::file_size_t size) override
	{
		if (!truncateProc)
			throw Permission_denied();
	}

	void move(Dir_handle, Name const &from,
	          Dir_handle, Name const &to) override
	{
		if (!moveProc)
			throw Permission_denied();
	}
};
