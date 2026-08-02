#import "PlatformStub.h"
#include <objc/message.h>
#include <cstdio>

// ============================================================
// SKPayment stub
// ============================================================
@implementation SKPayment {
    NSString* _pid;
}
+ (instancetype)paymentWithProductIdentifier:(NSString*)identifier {
    SKPayment* p = [[SKPayment alloc] init];
    p->_pid = identifier;
    return p;
}
- (NSString*)productIdentifier { return _pid; }
@end

// ============================================================
// SKPaymentQueue stub
// ============================================================
@implementation SKPaymentQueue
+ (SKPaymentQueue*)defaultQueue { static SKPaymentQueue* q; if(!q) q=[[SKPaymentQueue alloc] init]; return q; }
- (void)addPayment:(SKPayment*)p { printf("[SKPaymentQueue] addPayment: %s (not supported)\n", [p.productIdentifier UTF8String]); }
- (void)addTransactionObserver:(id)o {}
- (void)restoreCompletedTransactions {}
- (void)finishTransaction:(id)t {}
@end

// ============================================================
// SKProductsRequest stub
// ============================================================
@implementation SKProductsRequest {
    NSSet* _ids;
    id _delegate;
}
- (instancetype)initWithProductIdentifiers:(NSSet*)identifiers { self = [super init]; _ids = identifiers; return self; }
- (void)setDelegate:(id)d { _delegate = d; }
- (void)start {
    // Immediately callback with no products
    printf("[SKProductsRequest] start — returning empty (not supported)\n");
    if (_delegate && [_delegate respondsToSelector:@selector(productsRequest:didReceiveResponse:)]) {
        // Call with empty response
        SEL sel = @selector(productsRequest:didReceiveResponse:);
        void(*msg)(id,SEL,id,id) = (void(*)(id,SEL,id,id))objc_msgSend;
        msg(_delegate, sel, self, [NSMutableArray array]);
    }
}
@end

// ============================================================
// SKProduct stub
// ============================================================
@implementation SKProduct
@end

// ============================================================
// SKPaymentTransaction stub
// ============================================================
@implementation SKPaymentTransaction
@end
