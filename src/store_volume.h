/*
 * nix-linux-builder — store filesystem capabilities
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#ifndef NLB_STORE_VOLUME_H
#define NLB_STORE_VOLUME_H

#import <Foundation/Foundation.h>

/* Returns YES only when Foundation confirms the directory is on a
 * case-sensitive filesystem. Unknown or unavailable values fail closed. */
BOOL nlb_store_path_supports_case_sensitive_names(NSString *path,
                                                   NSString **reason);

#endif /* NLB_STORE_VOLUME_H */
