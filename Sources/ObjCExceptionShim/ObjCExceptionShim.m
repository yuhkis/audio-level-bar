#import "include/ObjCExceptionShim.h"

NSException *_Nullable ALBCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
