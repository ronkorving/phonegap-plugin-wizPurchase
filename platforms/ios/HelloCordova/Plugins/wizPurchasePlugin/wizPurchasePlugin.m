/* wizPurchasePlugin
 *
 * @author Ally Ogilvie
 * @copyright Wizcorp Inc. [ Incorporated Wizards ] 2014
 * @file wizPurchasePlugin.m
 *
 */

#import "wizPurchasePlugin.h"
#import "WizDebugLog.h"

@implementation wizPurchasePlugin

- (CDVPlugin *)initWithWebView:(UIWebView *)theWebView {

    if (self) {
        // Register ourselves as a transaction observer
        // (we get notified when payments in the payment queue get updated)
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    }
    return self;
}

- (BOOL)canMakePurchase {
    return [SKPaymentQueue canMakePayments];
}

- (void)canMakePurchase:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate runInBackground:^{
        CDVPluginResult *pluginResult;
        if ([self canMakePurchase]) {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        } else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR];
        }
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)restoreAll:(CDVInvokedUrlCommand *)command {
    WizLog(@"Restoring purchase");

    restorePurchaseCb = command.callbackId;
    // [self.commandDelegate runInBackground:^{
        // Call this to get any previously purchased non-consumables
        [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
    // }];
}

- (void)getProductDetail:(CDVInvokedUrlCommand *)command {
    WizLog(@"Getting products details");
    
    getProductDetailsCb = command.callbackId;
    [self.commandDelegate runInBackground:^{
        [self fetchProducts:[command.arguments objectAtIndex:0]];
    }];
}

- (void)consumePurchase:(CDVInvokedUrlCommand *)command {
    // Remove any receipt(s) from NSUserDefaults, we have verified with a server
    NSArray *receipts = [command.arguments objectAtIndex:0];
    for (NSString *reciept in receipts) {
        // Remove receipt from storage
        [self removeReciept:reciept];
    }
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)getPending:(CDVInvokedUrlCommand *)command {
    // Return contents of user defaults
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                       messageAsArray:[self fetchReceipts]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)makePurchase:(CDVInvokedUrlCommand *)command {
    NSString *productId = [command.arguments objectAtIndex:0];
    makePurchaseCb = command.callbackId;
    
    SKProduct *product = NULL;
    if (productsResponse != NULL) {
        // We have a made a product request before, check if we already called for this product
        
        for (SKProduct *obj in (NSArray *)productsResponse.products) {
            // Look for our requested product in the list of valid products
            if ([obj.productIdentifier isEqualToString:productId]) {
                // Found a valid matching product
                product = obj;
                break;
            }
        }
    }
    
    [self.commandDelegate runInBackground:^{
        if (product != NULL) {
            // We can shortcut an HTTP request, this product has been requested before
            [self productsRequest:NULL didReceiveResponse:(SKProductsResponse *)productsResponse];
        } else {
            // We need to fetch the product
            [self fetchProducts:@[ productId ]];
        }
    }];
    
}

- (void)fetchProducts:(NSArray *)productIdentifiers {
    WizLog(@"Fetching product information");
    // Build a SKProductsRequest for the identifiers provided
    SKProductsRequest *productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithArray:productIdentifiers]];
    productsRequest.delegate = self;
    [productsRequest start];
}

- (NSArray *)fetchReceipts {
    WizLog(@"Fetching receipts");
#if USE_ICLOUD_STORAGE
    NSUbiquitousKeyValueStore *storage = [NSUbiquitousKeyValueStore defaultStore];
#else
    NSUserDefaults *storage = [NSUserDefaults standardUserDefaults];
#endif
    
    NSArray *savedReceipts = [storage arrayForKey:@"receipts"];
    if (!savedReceipts) {
        // None found
        return @[ ];
    } else {
        // Return array
        return savedReceipts;
    }
}

- (void)removeReciept:(NSString *)receipt {
    WizLog(@"Removing receipt");
#if USE_ICLOUD_STORAGE
    NSUbiquitousKeyValueStore *storage = [NSUbiquitousKeyValueStore defaultStore];
#else
    NSUserDefaults *storage = [NSUserDefaults standardUserDefaults];
#endif

    NSMutableArray *savedReceipts = [storage objectForKey:@"receipts"];
    if (savedReceipts) {
        // Remove receipt
        [savedReceipts removeObject:receipt];
        [storage synchronize];
    }
}

- (void)backupReceipt:(NSString *)receipt {
    WizLog(@"Backing up receipt");
#if USE_ICLOUD_STORAGE
    NSUbiquitousKeyValueStore *storage = [NSUbiquitousKeyValueStore defaultStore];
#else
    NSUserDefaults *storage = [NSUserDefaults standardUserDefaults];
#endif
    
    NSArray *savedReceipts = [storage arrayForKey:@"receipts"];
    if (!savedReceipts) {
        // Storing the first receipt
        [storage setObject:@[receipt] forKey:@"receipts"];
    } else {
        // Adding another receipt
        NSArray *updatedReceipts = [savedReceipts arrayByAddingObject:receipt];
        [storage setObject:updatedReceipts forKey:@"receipts"];
    }
    [storage synchronize];
}

# pragma Methods for SKProductsRequestDelegate

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    WizLog(@"request - didFailWithError: %@", [[error userInfo] objectForKey:@"NSLocalizedDescription"]);
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    // Receiving a list of products from Apple
    
    if (makePurchaseCb != NULL) {
        
        if ([response.invalidProductIdentifiers count] > 0) {
            for (NSString *invalidProductId in response.invalidProductIdentifiers) {
                WizLog(@"Invalid product id: %@" , invalidProductId);
            }
            // We have requested at least one invalid product fallout here for security
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                              messageAsString:@"invalidProductId"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:makePurchaseCb];
            makePurchaseCb = NULL;
            return;
        }
        
        // Continue the purchase flow
        if ([response.products count] > 0) {
            SKProduct *product = [response.products objectAtIndex:0];
            SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
            [[SKPaymentQueue defaultQueue] addPayment:payment];
            
            return;
        }
        
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                          messageAsString:@"productNotFound"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:makePurchaseCb];
        makePurchaseCb = NULL;
    }
    
    if (getProductDetailsCb != NULL) {
        // Continue product(s) list request
        
        if ([response.invalidProductIdentifiers count] > 0) {
            for (NSString *invalidProductId in response.invalidProductIdentifiers) {
                WizLog(@"Invalid product id: %@" , invalidProductId);
            }
            // We have requested at least one invalid product fallout here for security
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                          messageAsString:@"invalidProductId"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:getProductDetailsCb];
            getProductDetailsCb = NULL;
            return;
        }
       
        // If you request all productIds we create a shortcut here for doing makePurchase
        // it saves on http requests
        productsResponse = (SKProductsResponse *)response;
        
        NSDictionary *product = NULL;
        NSMutableDictionary *productsDictionary = [[NSMutableDictionary alloc] init];
        WizLog(@"Products found: %i", [response.products count]);
        for (SKProduct *obj in response.products) {
            // Build a detailed product list from the list of valid products
            product = @{
                @"name":        obj.localizedTitle,
                @"price":       obj.price,
                @"priceLocale": obj.priceLocale.localeIdentifier,
                @"description": obj.localizedDescription
            };
            
            [productsDictionary setObject:product forKey:obj.productIdentifier];
        }
        
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:productsDictionary];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:getProductDetailsCb];
        getProductDetailsCb = NULL;
    }
}

# pragma Methods for SKPaymentTransactionObserver

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    if (restorePurchaseCb != NULL) {
        NSArray *receipts;
        if ([[[SKPaymentQueue defaultQueue] transactions] count] > 0) {
            for (SKPaymentTransaction *transaction in [[SKPaymentQueue defaultQueue] transactions]) {
                // Build array of restored receipt items
                [receipts arrayByAddingObject:[transaction transactionReceipt]];
            }
        } else {
            receipts = [[NSArray alloc] init];
        }

        // Return result to JavaScript
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                           messageAsArray:receipts];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:restorePurchaseCb];
        restorePurchaseCb = NULL;
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    if (restorePurchaseCb != NULL) {
        // Return result to JavaScript
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                          messageAsInt:error.code];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:restorePurchaseCb];
        restorePurchaseCb = NULL;
    }
}


- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {

	NSInteger errorCode = 0; // Set default unknown error
    NSString *error;
    for (SKPaymentTransaction *transaction in transactions) {
        
        switch (transaction.transactionState) {
			case SKPaymentTransactionStatePurchasing:
                WizLog(@"SKPaymentTransactionStatePurchasing");
				continue;
                
            { case SKPaymentTransactionStatePurchased:
                WizLog(@"SKPaymentTransactionStatePurchased");
                // Immediately save to NSUserDefaults incase we cannot reach JavaScript in time
                // or connection for server receipt verification is interupted
                NSString *receipt = [[NSString alloc] initWithData:[transaction transactionReceipt] encoding:NSUTF8StringEncoding];
                [self backupReceipt:receipt];

                if (makePurchaseCb) {
                    // We requested this payment let's finish
                    NSDictionary *result = @{
                         @"platform": @"ios",
                         @"receipt": receipt,
                         @"productId": transaction.payment.productIdentifier,
                         @"packageName": @"default"
                    };
                    // Return result to JavaScript
                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                                  messageAsDictionary:result];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:makePurchaseCb];
                    makePurchaseCb = NULL;
                }
                break;
            }
            case SKPaymentTransactionStateFailed:
            
				error = transaction.error.localizedDescription;
				errorCode = transaction.error.code;
				WizLog(@"SKPaymentTransactionStateFailed %d %@", errorCode, error);
                if (makePurchaseCb) {
                    // Return result to JavaScript
                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                                      messageAsString:[NSString stringWithFormat:@"SKPaymentTransactionStateFailed: %@", error]];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:makePurchaseCb];
                    makePurchaseCb = NULL;
                }
                break;
                
			case SKPaymentTransactionStateRestored:
                // We restored some non-consumable transactions add to receipt backup
				WizLog(@"SKPaymentTransactionStateRestored");
				[self backupReceipt:[[NSString alloc] initWithData:[transaction transactionReceipt] encoding:NSUTF8StringEncoding]];
                break;
                
            default:
				WizLog(@"SKPaymentTransactionStateInvalid");
                if (makePurchaseCb) {
                    // Return result to JavaScript
                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                                      messageAsString:[NSString stringWithFormat:@"SKPaymentTransactionStateInvalid: %@", error]];
                    [self.commandDelegate sendPluginResult:pluginResult callbackId:makePurchaseCb];
                    makePurchaseCb = NULL;
                }
                continue;
        }
        
        // Finishing a transaction tells Store Kit that you’ve completed everything needed for the purchase.
        // Unfinished transactions remain in the queue until they’re finished, and the transaction queue
        // observer is called every time your app is launched so your app can finish the transactions.
        // Your app needs to finish every transaction, regardles of whether the transaction succeeded or failed.
		[[SKPaymentQueue defaultQueue] finishTransaction:transaction];
    }
}

@end