//
//  ApplicationDelegate.m
//  PushMeBaby
//
//  Created by Stefan Hafeneger on 07.04.09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "ApplicationDelegate.h"

static NSString *deviceTokenKey = @"deviceToken";

@interface ApplicationDelegate () {
	otSocket socket;
	SSLContextRef context;
	SecKeychainRef keychain;
	SecCertificateRef certificate;
	SecIdentityRef identity;
}
#pragma mark Properties
@property(nonatomic, retain) NSString *deviceToken, *payload, *certificatePath;

@property (readonly) NSString *gateway;
@property (readonly) BOOL isSandbox;
@property (readonly) NSString *certificateName;

#pragma mark Private
- (void)connect;
- (void)disconnect;
@end

@implementation ApplicationDelegate

- (BOOL) isSandbox {
    return NO;
}

- (NSString *) gateway {
    if (self.isSandbox)
        return @"gateway.sandbox.push.apple.com";
    else
        return @"gateway.push.apple.com";
}

- (NSString *) certificateName {
    if (self.isSandbox)
        return @"aps_development";
    else
        return @"aps_production-wwdc";
    
}

#pragma mark Allocation

- (id)init {
	self = [super init];
	if(self != nil) {
		self.deviceToken = [[NSUserDefaults standardUserDefaults] valueForKey:deviceTokenKey];
        NSError *error = nil;
        NSData *payloadData = [NSJSONSerialization dataWithJSONObject:@{@"aps" : @{
                               @"alert" : @"This is some fancy message",
                               @"badge" : @0 }}
                                                                options:0 // NSJSONWritingPrettyPrinted
                                                                  error:&error];
		self.payload = [[[NSString alloc] initWithData:payloadData
                                              encoding:NSUTF8StringEncoding]
                        autorelease];
		self.certificatePath = [[NSBundle mainBundle] pathForResource:self.certificateName ofType:@"cer"];
	}
	return self;
}

- (void)dealloc {
	
	// Release objects.
	self.deviceToken = nil;
	self.payload = nil;
	self.certificatePath = nil;
	
	// Call super.
	[super dealloc];
	
}


#pragma mark Properties

@synthesize deviceToken = _deviceToken;
@synthesize payload;
@synthesize certificatePath;

- (void) setDeviceToken:(NSString *)deviceToken {
    if (_deviceToken != deviceToken) {
        [_deviceToken release];
        _deviceToken = [deviceToken retain];
        [[NSUserDefaults standardUserDefaults] setValue:_deviceToken forKey:deviceTokenKey];
    }
}

#pragma mark Inherent

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	[self connect];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
	[self disconnect];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
	return YES;
}

#pragma mark Private

- (void)connect {
	
	if(self.certificatePath == nil) {
		return;
	}
	
	// Define result variable.
	OSStatus result;
	
	// Establish connection to server.
	PeerSpec peer;
	result = MakeServerConnection([self.gateway cStringUsingEncoding:NSUTF8StringEncoding], 2195, &socket, &peer); NSLog(@"MakeServerConnection(): %d", result);
	
	// Create new SSL context.
	result = SSLNewContext(false, &context); NSLog(@"SSLNewContext(): %d", result);
	
	// Set callback functions for SSL context.
	result = SSLSetIOFuncs(context, SocketRead, SocketWrite); NSLog(@"SSLSetIOFuncs(): %d", result);
	
	// Set SSL context connection.
	result = SSLSetConnection(context, socket); NSLog(@"SSLSetConnection(): %d", result);
	
	// Set server domain name.
	result = SSLSetPeerDomainName(context, [self.gateway cStringUsingEncoding:NSUTF8StringEncoding], 30); NSLog(@"SSLSetPeerDomainName(): %d", result);
	
	// Open keychain.
	result = SecKeychainCopyDefault(&keychain); NSLog(@"SecKeychainOpen(): %d", result);
	
	// Create certificate.
	NSData *certificateData = [NSData dataWithContentsOfFile:self.certificatePath];
    
    certificate = SecCertificateCreateWithData(kCFAllocatorDefault, (CFDataRef)certificateData);
    if (certificate == NULL)
        NSLog (@"SecCertificateCreateWithData failled");
    
	// Create identity.
	result = SecIdentityCreateWithCertificate(keychain, certificate, &identity); NSLog(@"SecIdentityCreateWithCertificate(): %d", result);
	
	// Set client certificate.
	CFArrayRef certificates = CFArrayCreate(NULL, (const void **)&identity, 1, NULL);
	result = SSLSetCertificate(context, certificates); NSLog(@"SSLSetCertificate(): %d", result);
	CFRelease(certificates);
	
	// Perform SSL handshake.
	do {
		result = SSLHandshake(context); NSLog(@"SSLHandshake(): %d", result);
	} while(result == errSSLWouldBlock);
	
}

- (void)disconnect {
	
	if(self.certificatePath == nil) {
		return;
	}
	
	// Define result variable.
	OSStatus result;
	
	// Close SSL session.
	result = SSLClose(context);// NSLog(@"SSLClose(): %d", result);
	
	// Release identity.
    if (identity != NULL)
        CFRelease(identity);
	
	// Release certificate.
    if (certificate != NULL)
        CFRelease(certificate);
	
	// Release keychain.
    if (keychain != NULL)
        CFRelease(keychain);
	
	// Close connection to server.
	close((int)socket);
	
	// Delete SSL context.
	result = SSLDisposeContext(context);// NSLog(@"SSLDisposeContext(): %d", result);
	
}

#pragma mark IBAction

- (IBAction)push:(id)sender {
	
	if(self.certificatePath == nil) {
        NSLog(@"you need the APNS Certificate for the app to work");
        exit(1);
	}
	
	// Validate input.
	if(self.deviceToken == nil || self.payload == nil) {
		return;
	}
	
	// Convert string into device token data.
	NSMutableData *deviceToken = [NSMutableData data];
	unsigned value;
	NSScanner *scanner = [NSScanner scannerWithString:self.deviceToken];
	while(![scanner isAtEnd]) {
		[scanner scanHexInt:&value];
		value = htonl(value);
		[deviceToken appendBytes:&value length:sizeof(value)];
	}
	
	// Create C input variables.
	char *deviceTokenBinary = (char *)[deviceToken bytes];
	char *payloadBinary = (char *)[self.payload UTF8String];
	size_t payloadLength = strlen(payloadBinary);
	
	// Define some variables.
	uint8_t command = 0;
	char message[293];
	char *pointer = message;
	uint16_t networkTokenLength = htons(32);
	uint16_t networkPayloadLength = htons(payloadLength);
	
	// Compose message.
	memcpy(pointer, &command, sizeof(uint8_t));
	pointer += sizeof(uint8_t);
	memcpy(pointer, &networkTokenLength, sizeof(uint16_t));
	pointer += sizeof(uint16_t);
	memcpy(pointer, deviceTokenBinary, 32);
	pointer += 32;
	memcpy(pointer, &networkPayloadLength, sizeof(uint16_t));
	pointer += sizeof(uint16_t);
	memcpy(pointer, payloadBinary, payloadLength);
	pointer += payloadLength;
	
	// Send message over SSL.
	size_t processed = 0;
	OSStatus result = SSLWrite(context, &message, (pointer - message), &processed);
    if (result != noErr)
        NSLog(@"SSLWrite(): %d %zd", result, processed);
	
}

@end
