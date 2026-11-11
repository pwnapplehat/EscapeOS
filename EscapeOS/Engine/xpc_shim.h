/*
 * Minimal extern declarations for the two libxpc entry points worse_query.m
 * needs (xpc_string_create, xpc_release). This SDK copy does not ship
 * xpc/xpc.h, but libSystem.tbd (linked implicitly on iOS) exports both
 * symbols, so declaring the ABI directly here avoids needing the header.
 */
#ifndef VAULTPROBE_XPC_SHIM_H
#define VAULTPROBE_XPC_SHIM_H

typedef void *xpc_object_t;

extern xpc_object_t xpc_string_create(const char *string);
extern void xpc_release(xpc_object_t object);

#endif
