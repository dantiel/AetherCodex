#import <Foundation/Foundation.h>

/// Execute block, returning YES on success or NO if an NSException was thrown.
/// On exception, writes details to /tmp/aethercodex_crash.log.
BOOL AECatchException(void (^block)(void));
