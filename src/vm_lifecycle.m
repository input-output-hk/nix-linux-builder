/*
 * nix-linux-builder — VM lifecycle management
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 *
 * Runs a VZVirtualMachine on a dedicated serial dispatch queue.
 * Uses a semaphore to block the main thread until the VM terminates.
 * Handles:
 *   - Normal poweroff: read .exitcode from guest, return it
 *   - VM crash: return 255
 *   - Timeout: force-stop VM, return 254
 *   - SIGTERM/SIGINT: force-stop VM, return 253
 */

#import "vm_lifecycle.h"
#include "exitcode.h"
#include "log.h"

#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Signal handling via GCD dispatch sources ─────────────────────────────
 * Using dispatch sources instead of signal()/sigaction() because signal
 * handlers must be async-signal-safe — fprintf (LOG_WARN) and
 * dispatch_semaphore_signal are NOT. GCD dispatch sources run on a
 * queue, avoiding the async-signal-safety problem entirely. */

static dispatch_source_t create_signal_source(int sig,
                                               dispatch_queue_t queue,
                                               dispatch_semaphore_t sem,
                                               BOOL *signaled_flag)
{
    /* Ignore the signal via the default handler so the process doesn't
     * terminate — GCD will deliver it to our source instead. */
    signal(sig, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, queue);
    dispatch_source_set_event_handler(src, ^{
        LOG_WARN("received signal %d, stopping VM...", sig);
        /* Set flag before signaling semaphore so the main thread sees it
         * after waking (semaphore provides acquire/release ordering). */
        *signaled_flag = YES;
        dispatch_semaphore_signal(sem);
    });
    dispatch_resume(src);
    return src;
}

/* ── VM Delegate ──────────────────────────────────────────────────────────── */

@interface NLBVMDelegate : NSObject <VZVirtualMachineDelegate>
@property (atomic) dispatch_semaphore_t semaphore;
@property (atomic) BOOL crashed;
@property (atomic, strong) NSError *crashError;
@end

@implementation NLBVMDelegate

- (void)virtualMachine:(VZVirtualMachine *)vm didStopWithError:(NSError *)error
{
    (void)vm;
    LOG_ERR("VM stopped with error: %s", error.localizedDescription.UTF8String);
    self.crashed = YES;
    self.crashError = error;
    dispatch_semaphore_signal(self.semaphore);
}

- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)vm
{
    (void)vm;
    LOG_DBG("guest initiated poweroff");
    dispatch_semaphore_signal(self.semaphore);
}

@end

/* ── Force-stop helper ────────────────────────────────────────────────────── *
 * IMPORTANT: This must NOT be called from within dispatch_sync(vmQueue, ...)
 * because stopWithCompletionHandler: dispatches its completion block to
 * vmQueue. Blocking vmQueue while waiting for that completion would deadlock.
 *
 * Instead, this function dispatches the stop request asynchronously on
 * vmQueue and blocks the CALLING thread (main thread) on a semaphore.
 * The vmQueue remains free to process the completion handler. */

static void force_stop_vm(VZVirtualMachine *vm, dispatch_queue_t queue)
{
    dispatch_semaphore_t stop_sem = dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        if (vm.state == VZVirtualMachineStateStopped ||
            vm.state == VZVirtualMachineStateStopping) {
            dispatch_semaphore_signal(stop_sem);
            return;
        }
        [vm stopWithCompletionHandler:^(NSError *error) {
            if (error)
                LOG_ERR("force-stop error: %s", error.localizedDescription.UTF8String);
            dispatch_semaphore_signal(stop_sem);
        }];
    });
    /* Wait up to 5s on the calling thread (NOT on vmQueue). */
    long rc = dispatch_semaphore_wait(stop_sem,
        dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
    if (rc != 0)
        LOG_WARN("force-stop timed out after 5s — VM may still be running");
}

/* ── Public API ───────────────────────────────────────────────────────────── */

int nlb_vm_run(VZVirtualMachineConfiguration *config,
               const char *exitcode_path,
               unsigned int timeout_secs)
{
    @autoreleasepool {
        /* The VM must be created and managed on a serial dispatch queue,
         * as Virtualization.framework requires all VM operations to
         * happen on the same queue. */
        dispatch_queue_t vmQueue = dispatch_queue_create(
            "io.iohk.nix-linux-builder.vm", DISPATCH_QUEUE_SERIAL);

        __block VZVirtualMachine *vm = nil;
        dispatch_semaphore_t doneSem = dispatch_semaphore_create(0);

        NLBVMDelegate *delegate = [[NLBVMDelegate alloc] init];
        delegate.semaphore = doneSem;

        /* Install signal handlers via GCD dispatch sources.
         * The signaled flag is set by the handler before signaling doneSem,
         * so the main thread can distinguish signal wakeups from VM events. */
        __block BOOL signaled = NO;
        dispatch_source_t sigterm_src = create_signal_source(SIGTERM, vmQueue, doneSem, &signaled);
        dispatch_source_t sigint_src  = create_signal_source(SIGINT, vmQueue, doneSem, &signaled);

        /* Create and start the VM on the dedicated queue. */
        __block BOOL startFailed = NO;
        dispatch_sync(vmQueue, ^{
            vm = [[VZVirtualMachine alloc] initWithConfiguration:config
                                                           queue:vmQueue];
            vm.delegate = delegate;

            [vm startWithCompletionHandler:^(NSError *error) {
                if (error) {
                    LOG_ERR("VM start failed: %s",
                            error.localizedDescription.UTF8String);
                    startFailed = YES;
                    dispatch_semaphore_signal(doneSem);
                } else {
                    LOG_DBG("VM started successfully");
                }
            }];
        });

        /* Wait for VM to finish (poweroff, crash, timeout, or signal). */
        dispatch_time_t deadline = (timeout_secs > 0)
            ? dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)((uint64_t)timeout_secs * NSEC_PER_SEC))
            : DISPATCH_TIME_FOREVER;

        long result = dispatch_semaphore_wait(doneSem, deadline);

        int exit_code;

        if (startFailed) {
            exit_code = 255;
        } else if (result != 0) {
            /* Timeout */
            LOG_ERR("build timed out after %u seconds", timeout_secs);
            force_stop_vm(vm, vmQueue);
            exit_code = 254;
        } else if (signaled) {
            /* SIGTERM or SIGINT */
            force_stop_vm(vm, vmQueue);
            exit_code = 253;
        } else if (delegate.crashed) {
            exit_code = 255;
        } else {
            /* Normal poweroff — read the guest's exit code */
            exit_code = nlb_read_exitcode(exitcode_path);
            if (exit_code < 0) exit_code = 255;
        }

        /* Ensure VM is stopped before we return. Uses dispatch_async
         * internally to avoid deadlocking vmQueue. */
        force_stop_vm(vm, vmQueue);

        /* Cancel signal sources on vmQueue so that no signal handler can
         * fire after this point — the handlers capture &signaled (a
         * stack-local), so they must not execute after nlb_vm_run returns.
         * dispatch_sync is safe here because dispatch_source_cancel does
         * not block waiting for a completion handler. */
        dispatch_sync(vmQueue, ^{
            dispatch_source_cancel(sigterm_src);
            dispatch_source_cancel(sigint_src);
        });

        return exit_code;
    }
}
