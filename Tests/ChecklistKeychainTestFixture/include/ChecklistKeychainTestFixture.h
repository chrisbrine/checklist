#ifndef CHECKLIST_KEYCHAIN_TEST_FIXTURE_H
#define CHECKLIST_KEYCHAIN_TEST_FIXTURE_H
#include <Security/Security.h>
OSStatus ChecklistFixtureKeychainCreate(const char *path, UInt32 passwordLength, const void *password, Boolean promptUser, const SecAccessRef access, SecKeychainRef * CF_RETURNS_RETAINED keychain);
OSStatus ChecklistFixtureKeychainDelete(SecKeychainRef keychain);
#endif
