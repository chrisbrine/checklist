#import "ChecklistAXTestSupport.h"

id ChecklistTestAXAttributeValue(NSObject *object, NSAccessibilityAttributeName attribute) {
    // AXEnhancedUserInterface has no modern protocol equivalent; preserve fixture state.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [object accessibilityAttributeValue:attribute];
#pragma clang diagnostic pop
}

void ChecklistTestAXSetValue(NSObject *object, id value, NSAccessibilityAttributeName attribute) {
    // AXEnhancedUserInterface has no modern protocol setter; preserve native AX publication.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [object accessibilitySetValue:value forAttribute:attribute];
#pragma clang diagnostic pop
}
