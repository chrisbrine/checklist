#ifndef CHECKLIST_KEYCHAIN_TEST_FIXTURE_H
#define CHECKLIST_KEYCHAIN_TEST_FIXTURE_H
#include <Security/Security.h>
OSStatus ChecklistFixtureKeychainCreate(const char *path, UInt32 passwordLength, const void *password, Boolean promptUser, const SecAccessRef access, SecKeychainRef * CF_RETURNS_RETAINED keychain);
OSStatus ChecklistFixtureKeychainDelete(SecKeychainRef keychain);
OSStatus ChecklistTrustedApplicationCreateFromPath(const char *path, SecTrustedApplicationRef * CF_RETURNS_RETAINED application);
OSStatus ChecklistAccessCreate(CFStringRef descriptor, CFArrayRef applications, SecAccessRef * CF_RETURNS_RETAINED access);
#endif
