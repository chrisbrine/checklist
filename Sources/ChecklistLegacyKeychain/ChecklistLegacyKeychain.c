#include "ChecklistLegacyKeychain.h"
// File-based keychain ACLs ignore LAContext's no-UI setting. Preserve the
// process interaction guard and exact signed-executable ACL compatibility.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus ChecklistKeychainGetUserInteractionAllowed(Boolean *state) {
    return SecKeychainGetUserInteractionAllowed(state);
}
OSStatus ChecklistKeychainSetUserInteractionAllowed(Boolean state) {
    return SecKeychainSetUserInteractionAllowed(state);
}
OSStatus ChecklistTrustedApplicationCreateFromPath(const char *path, SecTrustedApplicationRef *application) {
    return SecTrustedApplicationCreateFromPath(path, application);
}
OSStatus ChecklistAccessCreate(CFStringRef descriptor, CFArrayRef applications, SecAccessRef *access) {
    return SecAccessCreate(descriptor, applications, access);
}
#pragma clang diagnostic pop
