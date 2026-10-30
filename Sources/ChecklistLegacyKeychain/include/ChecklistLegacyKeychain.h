#ifndef CHECKLIST_LEGACY_KEYCHAIN_H
#define CHECKLIST_LEGACY_KEYCHAIN_H
#include <Security/Security.h>
OSStatus ChecklistKeychainGetUserInteractionAllowed(Boolean *state);
OSStatus ChecklistKeychainSetUserInteractionAllowed(Boolean state);
#endif
