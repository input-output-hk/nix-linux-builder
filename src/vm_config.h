/*
 * nix-linux-builder — Virtualization.framework VM configuration
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#ifndef NLB_VM_CONFIG_H
#define NLB_VM_CONFIG_H

#import <Virtualization/Virtualization.h>
#include "cli.h"
#include "build_json.h"

/*
 * Create a fully configured VZVirtualMachineConfiguration for running a
 * Linux build guest. Sets up:
 *   - Linux boot loader with kernel + initrd
 *   - VirtioFS shares for nix store and build root
 *   - Serial console (hvc0) attached to host stdout
 *   - Entropy, memory balloon
 *   - Optional NAT networking
 *   - Optional Rosetta share for x86_64-linux builds
 *
 * Returns nil on failure (diagnostic printed to stderr).
 */
VZVirtualMachineConfiguration *nlb_create_vm_config(
    const nlb_cli_opts *opts,
    const nlb_build_spec *spec);

#endif /* NLB_VM_CONFIG_H */
