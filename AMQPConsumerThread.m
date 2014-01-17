//
//  AMQPConsumerThread.m
//  Objective-C wrapper for librabbitmq-c
//
//  Copyright 2009 Max Wolter. All rights reserved.
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#include <sys/ioctl.h>
#import "AMQPConsumerThread.h"
#import "AMQPWrapper.h"
#import "AMQPExchange+Additions.h"

#import <string.h>
#import <stdlib.h>

#import "AMQPConsumer.h"
#import "AMQPChannel.h"
#import "AMQPQueue.h"
#import "AMQPMessage.h"
#import "AMQPTTLManager.h"
#import "AMQPCommon.h"

NSString *const kCheckConnectionToken               = @"com.librabbitmq-objc.amqp.monitor-connection";
const NSTimeInterval kCheckConnectionInterval       = 30.0;
const NSTimeInterval kReconnectionInterval          = 1.0;
const NSUInteger kMaxReconnectionAttempts           = 3;

@interface AMQPConsumerThread() <AMQPTTLManagerDelegate>

@property (assign) BOOL checkConnectionTimerFired;
@property (assign) BOOL connectionErrorWasRaised;
@property (assign) BOOL started;
@property (assign) NSUInteger reconnectionCount;

@property (strong) NSDictionary *configuration;
@property (copy) NSString *topic;
@property (copy) NSString *exchangeKey;

@property (strong) AMQPTTLManager *ttlManager;
@property (strong) AMQPConnection *connection;
@property (strong) AMQPChannel *channel;
@property (strong) AMQPExchange *exchange;
@property (strong) AMQPQueue *queue;
@property (strong) AMQPConsumer *consumer;

@end

@implementation AMQPConsumerThread
{
    dispatch_queue_t    _callbackQueue;
}

#pragma mark - Dealloc and Initialization

- (void)dealloc
{
    [self _tearDown];
    
#if RABBITMQ_DISPATCH_RETAIN_RELEASE
    dispatch_release(_callbackQueue);
#endif
}

- (id)initWithConfiguration:(NSDictionary *)configuration
                exchangeKey:(NSString *)exchangeKey
                      topic:(NSString *)topic
                   delegate:(id)theDelegate
              callbackQueue:(dispatch_queue_t)callbackQueue
{
    if ((self = [super init])) {
        _configuration  = configuration;
        _exchangeKey    = exchangeKey;
        _topic          = topic;
        _delegate       = theDelegate;
        
        _ttlManager = [[AMQPTTLManager alloc] init];
        _ttlManager.delegate = self;
        
        _callbackQueue  = callbackQueue ? callbackQueue : dispatch_get_main_queue();
        
#if RABBITMQ_DISPATCH_RETAIN_RELEASE
        dispatch_retain(_callbackQueue);
#endif
    }
    
    return self;
}

#pragma mark - NSThread

- (void)main
{
    // atomicity of _started iVar (as now or as before using a lock queue) does not guarantee critical section for the entire method.
    // fix using appropriace lock mechanism and stop method accordingly (adebortoli 14.01.2014)
    @autoreleasepool {
        NSLog(@"<starting: consumer_thread: (%p) topic: %@>", self, _topic);
        NSError *error = nil;
        if (![self _setup:&error]) {
            NSLog(@"<starting: consumer_thread: (%p) topic: %@ :: failed to start>", self, _topic);
            NSLog(@"<starting: consumer_thread: (%p) topic: %@ :: error %@>", self, _topic, error);
            if ([self.delegate respondsToSelector:@selector(amqpConsumerThread:didFailWithError:)]) {
                dispatch_sync(_callbackQueue, ^{
                    [self.delegate amqpConsumerThread:self didFailWithError:error];
                });
            }
            return;
        }
        
        self.started = YES;
        
        if ([self.delegate respondsToSelector:@selector(amqpConsumerThreadDidStart:)]) {
            dispatch_sync(_callbackQueue, ^{
                [self.delegate amqpConsumerThreadDidStart:self];
            });
        }

        NSLog(@"<started: consumer_thread: (%p) topic: %@>", self, _topic);
        
        while(![self isCancelled]) {
            @autoreleasepool {
                AMQPMessage *message = [self _consume];
                if (message) {
                    NSLog(@"<consumer_thread: (%p) topic: %@ received message>", self, _topic);
                    dispatch_async(_callbackQueue, ^{
                        [self.delegate amqpConsumerThread:self didReceiveNewMessage:message];
                    });
                }
            }
        }
        
        NSLog(@"<stopping: consumer_thread: (%p) topic: %@>", self, _topic);
        [self _tearDown];
        NSLog(@"<stopped: consumer_thread: (%p) topic: %@>", self, _topic);
        
        self.started = NO;
        
        if ([self.delegate respondsToSelector:@selector(amqpConsumerThreadDidStop:)]) {
            dispatch_async(_callbackQueue, ^{
                [self.delegate amqpConsumerThreadDidStop:self];
            });
        }
    }
}

#pragma mark - Public Methods

- (void)stop
{
    [self cancel];
    
    BOOL stopped = NO;
    while(!stopped) { // this thing is WRONG (adebortoli 14.01.2014)
        stopped = !self.started;
    }
}

- (void)stopNoWait
{
    [self cancel];
}

#pragma mark - AMQPTTLManagerDelegate

- (void)ttlForObjectExpired:(id)object
{
    _checkConnectionTimerFired = YES;
}

#pragma mark - Private Methods - Setup & Tear down

- (BOOL)_setup:(NSError **)error
{
	// http://thecodinglove.com/post/72871562591/when-i-see-a-goto-in-a-legacy-code
    if (![self _connect:error])              goto HandleError;
    if (![self _setupExchange:error])        goto HandleError;
    if (![self _setupConsumerQueue:error])   goto HandleError;
    if (![self _setupConsumer:error])        goto HandleError;
    
    return YES;
    
    HandleError:
    [self _tearDown];
    return NO;
}

- (BOOL)_connect:(NSError **)outError
{
    NSString *host      = [_configuration objectForKey:@"host"];
    int port            = [[_configuration objectForKey:@"port"] intValue];
    NSString *username  = [_configuration objectForKey:@"username"];
    NSString *password  = [_configuration objectForKey:@"password"];
    NSString *vhost     = [_configuration objectForKey:@"vhost"];
    
    @try {
        NSLog(@"<consumer_thread (%p) topic: %@ :: connecting to host (%@:%d)...>", self, _topic, host, port);

        _connection = [[AMQPConnection alloc] init];
        [_connection connectToHost:host onPort:port];
        NSLog(@"<consumer_thread (%p) topic: %@ :: connected!>", self, _topic);
        
        NSLog(@"<consumer_thread (%p) topic: %@ :: authenticating user (%@)...>", self, _topic, username);
        [_connection loginAsUser:username withPassword:password onVHost:vhost];
        NSLog(@"<consumer_thread (%p) topic: %@ :: authenticated!>", self, _topic);
        
        _channel = [_connection openChannel];
        [_ttlManager addObject:kCheckConnectionToken ttl:kCheckConnectionInterval];
    }
    @catch(NSException *exception) {
        if (outError != NULL) {
            NSInteger errorCode = -1010;
            NSDictionary *userInfo = (@{
                                      NSLocalizedDescriptionKey         : exception.name,
                                      NSLocalizedFailureReasonErrorKey  : exception.reason});
            NSError *error = [NSError errorWithDomain:@"com.librabbitmq-objc.amqp" code:errorCode userInfo:userInfo];
            *outError = error;
        }
        return NO;
    }
    return YES;
}

- (BOOL)_setupExchange:(NSError **)outError
{
    @try {
        _exchange = [[AMQPExchange alloc] initTopicExchangeWithName:_exchangeKey
                                                          onChannel:_channel
                                                          isPassive:NO
                                                          isDurable:NO
                                                    getsAutoDeleted:YES];
    }
    @catch(NSException *exception) {
        if (outError != NULL) {
            NSInteger errorCode = -1010;
            NSDictionary *userInfo = (@{
                                      NSLocalizedDescriptionKey         : exception.name,
                                      NSLocalizedFailureReasonErrorKey  : exception.reason});
            NSError *error = [NSError errorWithDomain:@"com.librabbitmq-objc.amqp" code:errorCode userInfo:userInfo];
            *outError = error;
        }
    }
    return YES;
}

- (BOOL)_setupConsumerQueue:(NSError **)outError
{
    @try {
        _queue = [[AMQPQueue alloc] initWithName:@"com.librabbitmq-objc.amqp.queue"
                                       onChannel:_channel
                                       isPassive:NO
                                     isExclusive:NO
                                       isDurable:NO
                                 getsAutoDeleted:YES];
        [_queue bindToExchange:_exchange withKey:_topic];
    }
    @catch (NSException *exception) {
        if (outError != NULL) {
            NSInteger errorCode = -1010;
            NSDictionary *userInfo = (@{
                                      NSLocalizedDescriptionKey         : exception.name,
                                      NSLocalizedFailureReasonErrorKey  : exception.reason});
            NSError *error = [NSError errorWithDomain:@"com.librabbitmq-objc.amqp" code:errorCode userInfo:userInfo];
            *outError = error;
        }
        return NO;
    }
    return YES;
}

- (BOOL)_setupConsumer:(NSError **)outError
{
    @try {
        _consumer = [_queue startConsumerWithAcknowledgements:NO isExclusive:NO receiveLocalMessages:NO];
    }
    @catch (NSException *exception) {
        if (outError != NULL) {
            NSInteger errorCode = -1010;
            NSDictionary *userInfo = (@{
                                      NSLocalizedDescriptionKey         : exception.name,
                                      NSLocalizedFailureReasonErrorKey  : exception.reason});
            NSError *error = [NSError errorWithDomain:@"com.librabbitmq-objc.amqp" code:errorCode userInfo:userInfo];
            *outError = error;
        }
        return NO;
    }
    return YES;
}

- (void)_tearDown
{
    // NOTE: the order for the following operations is important
    // 1) consumer
    // 2) queue
    // 3) exchange
    // 4) channel
    // 5) connection

    // Note: if we don't currently have connectivity, some of these calls can
    // block for quite a bit (a few seconds)
    // (pdcgomes 21.03.2013)
    
    @try {
        _consumer = nil;
        @try {
            // if we're not connected, there's no point in attempting to unbind (pdcgomes 21.03.2013)
            if (!_connectionErrorWasRaised) {
                [_queue unbindFromExchange:_exchange withKey:_topic];
            }
        }
        @catch (NSException *exception) {
            NSLog(@"<consumer_thread (%p) exception triggered during tear down :: exception (%@) reason (%@)>", self, exception.name, exception.reason);
        }
        
        _exchange = nil;
        _queue = nil;
        _channel = nil;
        
        // if we're not connected, there's no point in attempting to disconnect (pdcgomes 21.03.2013)
        if (!_connectionErrorWasRaised) {
            [_connection disconnect];
        }
    }
    @catch (NSException *exception) {
        NSLog(@"<consumer_thread (%p) exception triggered during tear down :: exception (%@) reason (%@)>", self, exception.name, exception.reason);
    }
    @finally {
        _connection = nil;
        [_ttlManager removeAllObjects];
        _ttlManager = nil;
    }
}

#pragma mark - Private Methods - Message consuming loop

- (AMQPMessage *)_consume
{
	int     result = -1;
	size_t  receivedBytes = 0;
	size_t  bodySize = -1;
    
    amqp_bytes_t            body;
    amqp_frame_t            frame;
	amqp_basic_deliver_t    *delivery;
	amqp_basic_properties_t *properties;
    amqp_connection_state_t connection = _channel.connection.internalConnection;

    if (!connection) {
        return nil;
    }
    
	amqp_maybe_release_buffers(connection);

    AMQPMessage *message = nil;
    
	while(!message && ![self isCancelled]) {
        if (!amqp_frames_enqueued(connection) &&
            !amqp_data_in_buffer(connection)) {
            int sock = amqp_get_sockfd(connection);
            //                printf("socket: %d\n", sock);
            
            fd_set read_flags;
            int ret = 0;
            do {
                FD_ZERO(&read_flags);
                FD_SET(sock, &read_flags);
                
                struct timeval timeout;
                
                /* Wait upto a half a second. */
                timeout.tv_sec = 1;
                timeout.tv_usec = 0;
                
                ret = select(sock+1, &read_flags, NULL, NULL, &timeout);

                int bytesToRead = 0; ioctl(sock, FIONREAD, &bytesToRead);
                ioctl(sock, FIONREAD, &bytesToRead);

                if (ret == -1) {
                    NSLog(@"<consumer_thread (%p) topic %@ :: select() error (%s)>", self, _topic, strerror(errno));
                }
                if (_checkConnectionTimerFired) {
                    _checkConnectionTimerFired = NO;
//                    NSLog(@"<consumer_thread (%p) topic: %@ :: heartbeat>", self, _topic);
                    
                    // If we're idle for a long long time,
                    // the outer autorelease pool on consume will never drain because we're stuck here
                    // (pdcgomes 29.04.2013)
                    @autoreleasepool {
                        [_exchange publishMessage:@"Heartbeat" messageID:@"" payload:@"" usingRoutingKey:@"heartbeat"];
                    }
                    [_ttlManager addObject:kCheckConnectionToken ttl:kCheckConnectionInterval];
                }
                
                BOOL hasErrorCondition = (ret == -1 || (ret == 1 && bytesToRead == 0));
                if (hasErrorCondition) {
                    goto HandleFrameError;
                }
            } while (ret == 0 && ![self isCancelled]);
            
        }

        if ([self isCancelled]) {
            break;
        }
        
		// a complete message delivery consists of at least three frames:
        // Frame #1: method frame with method basic.deliver
		// Frame #2: header frame containing body size
		// Frame #3+: body frames

        // Frame #1: method frame with method basic.deliver
		result = amqp_simple_wait_frame(connection, &frame);
		if (result < 0) {
            NSLog(@"<consumer_thread (%p) topic %@ :: frame #1 error (%d)>", self, _topic, result);
            NSLog(@"frame #1 resut = %d", result);
            goto HandleFrameError;
        }
		
		if (frame.frame_type != AMQP_FRAME_METHOD ||
           frame.payload.method.id != AMQP_BASIC_DELIVER_METHOD) {
            continue;
        }
		
		delivery = (amqp_basic_deliver_t *)frame.payload.method.decoded;
		
        // Frame #2: header frame containing body size
		result = amqp_simple_wait_frame(connection, &frame);
		if (result < 0) {
            NSLog(@"<consumer_thread (%p) topic %@ :: frame #2 error (%d)>", self, _topic, result);
            goto HandleFrameError;
        }
		 
		if (frame.frame_type != AMQP_FRAME_HEADER) {
            NSLog(@"frame.frame_type != AMQP_FRAME_HEADER");
			return nil;
		}
		
		properties = (amqp_basic_properties_t *)frame.payload.properties.decoded;
		
		bodySize = (size_t)frame.payload.properties.body_size;
		receivedBytes = 0;
		body = amqp_bytes_malloc(bodySize);
		
        // Frame #3+: body frames
		while(receivedBytes < bodySize) {
			result = amqp_simple_wait_frame(connection, &frame);
			if (result < 0) {
                NSLog(@"<consumer_thread (%p) topic %@ :: frame #3 error (%d)>", self, _topic, result);
                goto HandleFrameError;
            }
			
			if (frame.frame_type != AMQP_FRAME_BODY) {
                NSLog(@"frame.frame_type != AMQP_FRAME_BODY");
				return nil;
			}
			
			receivedBytes += frame.payload.body_fragment.len;
			memcpy(body.bytes, frame.payload.body_fragment.bytes, frame.payload.body_fragment.len);
		}
        
		message = [AMQPMessage messageFromBody:body withDeliveryProperties:delivery withMessageProperties:properties receivedAt:[NSDate date]];
		amqp_bytes_free(body);
	}
	
	return message;
    
    HandleFrameError:
    [self _handleConnectionError];

    return nil;
}

- (void)_handleConnectionError
{
    BOOL isConnected = [_connection checkConnection];

    if (!isConnected) {
        if ([self _attemptToReconnect]) {
            return;
        }
        if ([self isCancelled]) {
            return;
        };
    }

    _connectionErrorWasRaised = YES;
    
    dispatch_async(_callbackQueue, ^{
        if ([self.delegate respondsToSelector:@selector(amqpConsumerThread:reportedError:)]) {
            NSString *errorDescription = nil;
            NSString *failureReason = nil;
            if (!isConnected) {
                errorDescription    = @"Connection closed";
                failureReason       = @"The connection has been unexpectedly closed";
            }
            else {
                errorDescription    = @"Connection error";
                failureReason       = @"There was an unexpected error while attempting to process incoming data";
            }
            NSDictionary *userInfo = (@{
                                      NSLocalizedDescriptionKey : errorDescription,
                                      NSLocalizedFailureReasonErrorKey : failureReason});
            NSError *error = [NSError errorWithDomain:@"com.librabbitmq-objc.amqp"
                                                 code:-10
                                             userInfo:userInfo];
            [self.delegate amqpConsumerThread:self reportedError:error];
        }
    });
}

- (BOOL)_attemptToReconnect
{
    BOOL success = NO;
    
    _reconnectionCount = 0;
    while(_reconnectionCount < kMaxReconnectionAttempts) {
        if ([self isCancelled]) {
            break;
        };
        
        _reconnectionCount++;
        
        NSLog(@"<reconnect: consumer_thread: (%p) topic: %@ :: reconnection attempt #%d...>", self, _topic, _reconnectionCount);
        
        [self _tearDown];
        
        NSError *error = nil;
        if ([self _setup:&error]) {
            NSLog(@"<reconnect: consumer_thread: (%p) topic: %@ :: reconnected successfully!>", self, _topic);
            success = YES;
            break;
        }
        else {
            NSLog(@"<reconnect: consumer_thread: (%p) topic: %@ :: failed to reconnect>", self, _topic);
            NSLog(@"<reconnect: consumer_thread: (%p) topic: %@ :: error %@>", self, _topic, error);
            [NSThread sleepForTimeInterval:kReconnectionInterval];
        }
    }

    return success;
}

@end
