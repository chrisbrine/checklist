#include "ChecklistKeychainTestFixture.h"
// Keep the isolated file-keychain ACL fixture and teardown: SecItem APIs cannot
// create/delete a keychain, and switching stores would lose legacy ACL coverage.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus ChecklistFixtureKeychainCreate(const char *path, UInt32 passwordLength, const void *password, Boolean promptUser, const SecAccessRef access, SecKeychainRef *keychain) {
    return SecKeychainCreate(path, passwordLength, password, promptUser, access, keychain);
}
OSStatus ChecklistFixtureKeychainDelete(SecKeychainRef keychain) {
    return SecKeychainDelete(keychain);
}
// The old ACL shape of a pairing item, kept only for the skipped fixture class.
OSStatus ChecklistTrustedApplicationCreateFromPath(const char *path, SecTrustedApplicationRef *application) {
    return SecTrustedApplicationCreateFromPath(path, application);
}
OSStatus ChecklistAccessCreate(CFStringRef descriptor, CFArrayRef applications, SecAccessRef *access) {
    return SecAccessCreate(descriptor, applications, access);
}
#pragma clang diagnostic pop
