#include "ChecklistLegacyKeychain.h"
// File-based keychain ACLs ignore LAContext's no-UI setting. Keep the process
// interaction guard for the one CL-374 migration read and its removal condition.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus ChecklistKeychainGetUserInteractionAllowed(Boolean *state) {
    return SecKeychainGetUserInteractionAllowed(state);
}
OSStatus ChecklistKeychainSetUserInteractionAllowed(Boolean state) {
    return SecKeychainSetUserInteractionAllowed(state);
}
#pragma clang diagnostic pop
