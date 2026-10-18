/*
 * nix-linux-builder — store filesystem capabilities
 * Copyright 2025 Moritz Angermann <moritz@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#import "store_volume.h"

BOOL nlb_store_path_supports_case_sensitive_names(NSString *path,
                                                   NSString **reason)
{
    if (reason)
        *reason = nil;

    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        if (reason)
            *reason = @"store path is empty or invalid";
        return NO;
    }

    NSURL *url = [[NSURL fileURLWithPath:path isDirectory:YES]
        URLByResolvingSymlinksInPath];
    NSNumber *isDirectory = nil;
    NSError *error = nil;
    if (![url getResourceValue:&isDirectory
                        forKey:NSURLIsDirectoryKey
                         error:&error]) {
        if (reason)
            *reason = [NSString stringWithFormat:
                @"cannot inspect store path '%@': %@", path,
                error.localizedDescription ?: @"unknown filesystem error"];
        return NO;
    }
    if (![isDirectory isKindOfClass:[NSNumber class]] || !isDirectory.boolValue) {
        if (reason)
            *reason = [NSString stringWithFormat:
                @"store path '%@' is not a directory", path];
        return NO;
    }

    NSNumber *supportsCaseSensitiveNames = nil;
    error = nil;
    if (![url getResourceValue:&supportsCaseSensitiveNames
                        forKey:NSURLVolumeSupportsCaseSensitiveNamesKey
                         error:&error]) {
        if (reason)
            *reason = [NSString stringWithFormat:
                @"cannot determine whether the store filesystem at '%@' "
                 "supports case-sensitive names: %@", path,
                error.localizedDescription ?: @"unknown filesystem error"];
        return NO;
    }
    if (![supportsCaseSensitiveNames isKindOfClass:[NSNumber class]]) {
        if (reason)
            *reason = [NSString stringWithFormat:
                @"filesystem case sensitivity for store path '%@' is unknown", path];
        return NO;
    }

    if (!supportsCaseSensitiveNames.boolValue && reason)
        *reason = [NSString stringWithFormat:
            @"store filesystem at '%@' does not support case-sensitive names", path];
    return supportsCaseSensitiveNames.boolValue;
}
