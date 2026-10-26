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
#pragma clang diagnostic pop
