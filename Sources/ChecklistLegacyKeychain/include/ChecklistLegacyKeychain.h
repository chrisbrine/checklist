#ifndef CHECKLIST_LEGACY_KEYCHAIN_H
#define CHECKLIST_LEGACY_KEYCHAIN_H
#include <Security/Security.h>
OSStatus ChecklistKeychainGetUserInteractionAllowed(Boolean *state);
OSStatus ChecklistKeychainSetUserInteractionAllowed(Boolean state);
OSStatus ChecklistTrustedApplicationCreateFromPath(const char *path, SecTrustedApplicationRef * CF_RETURNS_RETAINED application);
OSStatus ChecklistAccessCreate(CFStringRef descriptor, CFArrayRef applications, SecAccessRef * CF_RETURNS_RETAINED access);
#endif
