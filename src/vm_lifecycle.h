/*
 * nix-linux-builder — VM lifecycle management
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#ifndef NLB_VM_LIFECYCLE_H
#define NLB_VM_LIFECYCLE_H

#import <Virtualization/Virtualization.h>

/*
 * Run a VM to completion. Blocks the calling thread until the VM
 * powers off, crashes, or the timeout expires.
 *
 * @param config      Validated VM configuration.
 * @param exitcode_path  Path to the file where the guest writes its exit code
 *                       (typically topTmpDir/.exitcode).
 * @param timeout_secs   Maximum seconds to wait (0 = no timeout).
 *
 * Returns the builder's exit code (from .exitcode file), or:
 *   - 255 on VM crash or internal error
 *   - 254 on timeout
 *   - 253 on signal
 */
int nlb_vm_run(VZVirtualMachineConfiguration *config,
               const char *exitcode_path,
               unsigned int timeout_secs);

#endif /* NLB_VM_LIFECYCLE_H */
