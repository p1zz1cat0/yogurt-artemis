#pragma once

// StoreKit stubs — return "not supported" for all IAP calls

#ifdef __OBJC__
#import <Foundation/Foundation.h>

@interface SKPayment : NSObject
+ (instancetype)paymentWithProductIdentifier:(NSString*)identifier;
@property (nonatomic, readonly) NSString* productIdentifier;
@end

@interface SKPaymentQueue : NSObject
+ (SKPaymentQueue*)defaultQueue;
- (void)addPayment:(SKPayment*)payment;
- (void)addTransactionObserver:(id)observer;
- (void)restoreCompletedTransactions;
- (void)finishTransaction:(id)transaction;
@end

@interface SKProductsRequest : NSObject
- (instancetype)initWithProductIdentifiers:(NSSet*)identifiers;
- (void)setDelegate:(id)delegate;
- (void)start;
@end

@interface SKProduct : NSObject
@property (nonatomic, readonly) NSString* productIdentifier;
@property (nonatomic, readonly) NSString* localizedTitle;
@property (nonatomic, readonly) NSString* localizedDescription;
@property (nonatomic, readonly) NSDecimalNumber* price;
@property (nonatomic, readonly) NSLocale* priceLocale;
@end

// Payment transaction
@interface SKPaymentTransaction : NSObject
@property (nonatomic, readonly) NSInteger transactionState;
@property (nonatomic, readonly) SKPayment* payment;
@property (nonatomic, readonly) NSError* error;
@property (nonatomic, readonly) NSData* transactionReceipt;
@property (nonatomic, readonly) NSString* transactionIdentifier;
@end

#endif
