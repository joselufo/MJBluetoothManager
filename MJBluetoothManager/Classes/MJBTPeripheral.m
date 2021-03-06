//
// Created by Paolo Tagliani on 10/05/16.
// Copyright (c) 2016 Mobile Jazz. All rights reserved.
//

#import "MJBTPeripheral.h"
#import "CBPeripheral+Helper.h"
#import "NSError+Utilities.h"
#import "MJBTErrorConstants.h"

@interface MJBTPeripheral ()

@property (nonatomic, strong, readwrite) CBPeripheral *BTPeripheral;

/*
 * Completion blocks
 */
@property (nonatomic, copy, readwrite) void (^ MJBTServiceDiscoveryBlock)(NSArray <CBService *> *services, NSError *error);
@property (nonatomic, copy, readwrite) void (^ MJBTCharacteristicDiscoveryBlock)(NSError *error);
@property (nonatomic, copy, readwrite) void (^ MJBTCharacteristicsListReadBlock)(NSDictionary *data, NSError *error);

/*
 * Read/write blocks storage
 */
@property (strong, nonatomic, readwrite) NSMapTable *characteristicReadBlocks;
@property (strong, nonatomic, readwrite) NSMapTable *characteristicWriteBlocks;
@property (strong, nonatomic, readwrite) NSMapTable *characteristicNotificationSubscriptionBlocks;

/*
 * Temp variables
 */
@property (nonatomic, strong, readwrite) NSMutableArray <CBService *> *temporaryServiceArray;
@property (nonatomic, strong, readwrite) NSMutableArray <NSString *> *tempReadCharacteristicsArray;
@property (nonatomic, strong, readwrite) NSMutableDictionary <NSString *, NSData *> *tempReadCharacteristicsValues;

@end

@implementation MJBTPeripheral

- (instancetype)initWithPeripheral:(CBPeripheral *)btPeripheral
{
    self = [super init];
    if (self)
    {
        _BTPeripheral = btPeripheral;
        _BTPeripheral.delegate = self;

        _characteristicReadBlocks = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsCopyIn capacity:10];
        _characteristicWriteBlocks = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsCopyIn capacity:10];
        _characteristicNotificationSubscriptionBlocks = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsCopyIn capacity:10];
    }

    return self;
}

#pragma mark - Utilities

- (void)setupPeripheralForUse:(void (^)(NSError *error))completionBlock
{
    [self listServices:^(NSArray *services, NSError *servicesError) {
        if (servicesError)
        {
            if (completionBlock)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(servicesError);
                });
            }
            return;
        }
        [self listCharacteristics:^(NSError *characteristicsError) {
            if (completionBlock)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(characteristicsError);
                });
            }
        }];
    }];
}

#pragma mark - Getter

- (NSData *)getValueForCharacteristic:(NSString *)characteristicID
{
    CBCharacteristic *characteristic = [_BTPeripheral characteristicWithID:characteristicID];

    return characteristic.value;
}

- (NSString *)identifier
{
    return [_BTPeripheral.identifier UUIDString];
}

#pragma mark - Public methods

- (BOOL)isConnected
{
    return _BTPeripheral.state == CBPeripheralStateConnected;
}

- (NSArray <CBService *> *)services
{
    return _BTPeripheral.services;
}

- (NSArray <CBCharacteristic *> *)characteristics
{
    NSMutableArray *characteristics = [NSMutableArray array];

    for (CBService *service in _BTPeripheral.services)
    {
        [characteristics addObjectsFromArray:service.characteristics];
    }

    return [NSArray arrayWithArray:characteristics];
}

#pragma mark - Services management

- (void)listServices:(void (^)(NSArray <CBService *> *services, NSError *error))completionBlock
{
    if (_BTPeripheral.state != CBPeripheralStateConnected)
    {
        completionBlock(nil, [NSError createErrorWithDomain:MJBTErrorDomain code:MJBTErrorCodeDeviceNotConnected description:nil]);
        return;
    }

    self.MJBTServiceDiscoveryBlock = completionBlock;
    [_BTPeripheral discoverServices:nil];
}

#pragma mark - Characteristic management

- (void)listCharacteristics:(void (^)(NSError *))completionBlock
{
    self.MJBTCharacteristicDiscoveryBlock = completionBlock;
    NSArray *services = _BTPeripheral.services;
    self.temporaryServiceArray = [services mutableCopy];

    [self mj_discoverNextCharacteristic];
}

- (void)readCharacteristic:(NSString *)characteristicID completionBlock:(void (^)(NSData *value, NSError *error))completionBlock
{
    [_characteristicReadBlocks setObject:completionBlock forKey:characteristicID];

    CBCharacteristic *characteristic = [_BTPeripheral characteristicWithID:characteristicID];

    if (!characteristic)
    {
        completionBlock(nil, [NSError createErrorWithDomain:MJBTErrorDomain code:MJBTErrorCodeCharacteristicNotExists description:nil]);
        return;
    }

    [_BTPeripheral readValueForCharacteristic:characteristic];
}

- (void)readCharacteristics:(NSArray <NSString *> *)characteristicsID completionBlock:(void (^)(NSDictionary <NSString *, NSData *> *values, NSError *error))completionBlock
{
    self.MJBTCharacteristicsListReadBlock = completionBlock;

    self.tempReadCharacteristicsArray = [characteristicsID mutableCopy];
    self.tempReadCharacteristicsValues = [NSMutableDictionary dictionary];
    [self mj_readNextCharacteristic];
}

- (void)writeCharacteristic:(NSString *)characteristicID data:(NSData *)data completionBlock:(void (^)(NSError *error))completionBlock
{
    [_characteristicWriteBlocks setObject:completionBlock forKey:characteristicID];
    CBCharacteristic *characteristic = [_BTPeripheral characteristicWithID:characteristicID];
    if (!characteristic)
    {
        completionBlock([NSError createErrorWithDomain:MJBTErrorDomain code:MJBTErrorCodeCharacteristicNotExists description:nil]);
        return;
    }

    [_BTPeripheral writeValue:data forCharacteristic:characteristic type:CBCharacteristicWriteWithResponse];
}

- (void)subscribeCharacteristicNotification:(NSString *)characteristicID completionBlock:(void (^)(NSError *error))completionBlock
{
    [_characteristicNotificationSubscriptionBlocks setObject:completionBlock forKey:characteristicID];
    CBCharacteristic *characteristic = [_BTPeripheral characteristicWithID:characteristicID];

    [_BTPeripheral setNotifyValue:YES forCharacteristic:characteristic];
}

#pragma mark - Private methods

- (void)mj_discoverNextCharacteristic
{
    if (self.temporaryServiceArray.count != 0)
    {
        CBService *service = [self.temporaryServiceArray lastObject];
        [_BTPeripheral discoverCharacteristics:nil forService:service];
    }
    else
    {
        __weak typeof(self) weakSelf = self;
        if (_MJBTCharacteristicDiscoveryBlock)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.MJBTCharacteristicDiscoveryBlock(nil);
            });
        }
    }
}

- (void)mj_readNextCharacteristic
{
    if (_tempReadCharacteristicsArray.count != 0)
    {
        CBCharacteristic *characteristic = [_BTPeripheral characteristicWithID:[_tempReadCharacteristicsArray lastObject]];
        [_BTPeripheral readValueForCharacteristic:characteristic];
    }
    else
    {
        self.tempReadCharacteristicsArray = nil;
        NSDictionary *values = [_tempReadCharacteristicsValues copy];

        if (_MJBTCharacteristicsListReadBlock)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                _MJBTCharacteristicsListReadBlock(values, nil);
            });
        }
    }
}

#pragma mark BTPeripheralDelegate methods

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    NSArray *services = error ? nil : peripheral.services;

    if (_MJBTServiceDiscoveryBlock)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            _MJBTServiceDiscoveryBlock(services, error);
        });
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    if (error)
    {
        if (_MJBTCharacteristicDiscoveryBlock)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                _MJBTCharacteristicDiscoveryBlock(error);
            });
        }
    }
    else
    {
        [_temporaryServiceArray removeLastObject];
        [self mj_discoverNextCharacteristic];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    // Check if it's a sequencial reading
    if (_tempReadCharacteristicsArray.count != 0 && [_tempReadCharacteristicsArray containsObject:[characteristic.UUID UUIDString]])
    {
        if (error)
        {
            NSDictionary *values = [_tempReadCharacteristicsValues copy];

            if (_MJBTCharacteristicsListReadBlock)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    _MJBTCharacteristicsListReadBlock(values, error);
                });
            }
            return;
        }

        _tempReadCharacteristicsValues[[characteristic.UUID UUIDString]] = characteristic.value;
        [_tempReadCharacteristicsArray removeObject:[characteristic.UUID UUIDString]];
        [self mj_readNextCharacteristic];
        return;
    }

    // Check if there's a single reading goind on, otherwise it's a notification
    void (^ characteristicReadBLock)(NSData *data, NSError *readError) = [_characteristicReadBlocks objectForKey:[characteristic.UUID UUIDString]];
    if (!characteristicReadBLock)
    { // It's a notification and need to be updated asynchronously
        if ([_notificationDelegate respondsToSelector:@selector(didNotifiedValue:forCharacteristicID:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_notificationDelegate didNotifiedValue:characteristic.value forCharacteristicID:[characteristic.UUID UUIDString]];
            });
        }
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            characteristicReadBLock(characteristic.value, error);
        });
        [_characteristicReadBlocks removeObjectForKey:[characteristic.UUID UUIDString]];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    void (^ notificationBlock)(NSError *errorSubscription) = [_characteristicNotificationSubscriptionBlocks objectForKey:[characteristic.UUID UUIDString]];
    if (notificationBlock)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            notificationBlock(error);
            [_characteristicNotificationSubscriptionBlocks removeObjectForKey:[characteristic.UUID UUIDString]];
        });
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    void (^ writeBlock)(NSError *writeError) = [_characteristicWriteBlocks objectForKey:[characteristic.UUID UUIDString]];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (writeBlock)
        {
            writeBlock(error);
        }
    });
    [_characteristicWriteBlocks removeObjectForKey:[characteristic.UUID UUIDString]];
}

@end
