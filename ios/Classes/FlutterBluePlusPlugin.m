// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#import "FlutterBluePlusPlugin.h"

#define Log(LEVEL, FORMAT, ...) [self log:LEVEL format:@"[FBP-iOS] " FORMAT, ##__VA_ARGS__]

NSString * const CCCD = @"00002902-0000-1000-8000-00805f9b34fb";

@interface ServicePair : NSObject
@property (strong, nonatomic) CBService *primary;
@property (strong, nonatomic) CBService *secondary;
@end

@implementation ServicePair
@end

@interface CBUUID (CBUUIDAdditionsFlutterBluePlus)
- (NSString *)uuidStr;
@end

@implementation CBUUID (CBUUIDAdditionsFlutterBluePlus)
- (NSString *)uuidStr
{
    return [self.UUIDString lowercaseString];
}
@end

typedef NS_ENUM(NSUInteger, LogLevel) {
    LNONE = 0,
    LERROR = 1,
    LWARNING = 2,
    LINFO = 3,
    LDEBUG = 4,
    LVERBOSE = 5,
};

@interface FlutterBluePlusPlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *methodChannel;
@property(nonatomic, retain) CBCentralManager *centralManager;
@property(nonatomic) NSMutableDictionary *knownPeripherals;
@property(nonatomic) NSMutableDictionary *connectedPeripherals;
@property(nonatomic) NSMutableDictionary *currentlyConnectingPeripherals;
@property(nonatomic) NSMutableArray *servicesThatNeedDiscovered;
@property(nonatomic) NSMutableArray *characteristicsThatNeedDiscovered;
@property(nonatomic) NSMutableDictionary *didWriteWithoutResponse;
@property(nonatomic) NSMutableDictionary *peripheralMtu;
@property(nonatomic) NSMutableDictionary *writeChrs;
@property(nonatomic) NSMutableDictionary *writeDescs;
@property(nonatomic) NSMutableDictionary *scanCounts;
@property(nonatomic) NSDictionary *scanFilters;
@property(nonatomic) NSTimer *checkForMtuChangesTimer;
@property(nonatomic) LogLevel logLevel;
@end

@implementation FlutterBluePlusPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
{
    FlutterMethodChannel *methodChannel = [FlutterMethodChannel methodChannelWithName:NAMESPACE @"/methods"
                                                                binaryMessenger:[registrar messenger]];
    FlutterBluePlusPlugin *instance = [[FlutterBluePlusPlugin alloc] init];
    instance.methodChannel = methodChannel;
    instance.knownPeripherals = [NSMutableDictionary new];
    instance.connectedPeripherals = [NSMutableDictionary new];
    instance.currentlyConnectingPeripherals = [NSMutableDictionary new];
    instance.servicesThatNeedDiscovered = [NSMutableArray new];
    instance.characteristicsThatNeedDiscovered = [NSMutableArray new];
    instance.didWriteWithoutResponse = [NSMutableDictionary new];
    instance.peripheralMtu = [NSMutableDictionary new];
    instance.writeChrs = [NSMutableDictionary new];
    instance.writeDescs = [NSMutableDictionary new];
    instance.scanCounts = [NSMutableDictionary new];
    instance.logLevel = LDEBUG;

    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

////////////////////////////////////////////////////////////
// ██   ██   █████   ███    ██  ██████   ██       ███████    
// ██   ██  ██   ██  ████   ██  ██   ██  ██       ██         
// ███████  ███████  ██ ██  ██  ██   ██  ██       █████      
// ██   ██  ██   ██  ██  ██ ██  ██   ██  ██       ██         
// ██   ██  ██   ██  ██   ████  ██████   ███████  ███████                                                       
//                                                      
// ███    ███  ███████  ████████  ██   ██   ██████   ██████  
// ████  ████  ██          ██     ██   ██  ██    ██  ██   ██ 
// ██ ████ ██  █████       ██     ███████  ██    ██  ██   ██ 
// ██  ██  ██  ██          ██     ██   ██  ██    ██  ██   ██ 
// ██      ██  ███████     ██     ██   ██   ██████   ██████                                              
//                                                      
//  ██████   █████   ██       ██                           
// ██       ██   ██  ██       ██                           
// ██       ███████  ██       ██                           
// ██       ██   ██  ██       ██                           
//  ██████  ██   ██  ███████  ███████                     

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result
{
    @try
    {
        Log(LDEBUG, @"handleMethodCall: %@", call.method);

        // initialize adapter
        if (self.centralManager == nil)
        {
            Log(LDEBUG, @"initializing CBCentralManager");

            NSDictionary *options = @{
                CBCentralManagerOptionShowPowerAlertKey: @(YES)
            };

            self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:options];
        }
        // initialize timer
        if (self.checkForMtuChangesTimer == nil)
        {
            Log(LDEBUG, @"initializing checkForMtuChangesTimer");

            self.checkForMtuChangesTimer = [NSTimer scheduledTimerWithTimeInterval:0.025
                target:self
                selector:@selector(checkForMtuChangesCallback) 
                userInfo:@{}
                repeats:YES];
        }
        // check that we have an adapter, except for the 
        // functions that don't need it
        if (self.centralManager == nil && 
            [@"flutterHotRestart" isEqualToString:call.method] == false &&
            [@"connectedCount" isEqualToString:call.method] == false &&
            [@"setLogLevel" isEqualToString:call.method] == false &&
            [@"isSupported" isEqualToString:call.method] == false &&
            [@"getAdapterName" isEqualToString:call.method] == false &&
            [@"getAdapterState" isEqualToString:call.method] == false) {
            NSString* s = @"the device does not support bluetooth";
            result([FlutterError errorWithCode:@"bluetoothUnavailable" message:s details:NULL]);
            return;
        }

        if ([@"flutterHotRestart" isEqualToString:call.method])
        {
            // no adapter?
            if (self.centralManager == nil) {
                result(@(0)); // no work to do
                return;
            }

            if ([self isAdapterOn]) {
                [self.centralManager stopScan];
            }

            [self disconnectAllDevices:@"flutterHotRestart"];

            Log(LDEBUG, @"connectedPeripherals: %lu", self.connectedPeripherals.count);

            if (self.connectedPeripherals.count == 0) {
                [self.knownPeripherals removeAllObjects];
            }
            
            result(@(self.connectedPeripherals.count));
            return;
        }
        else if ([@"connectedCount" isEqualToString:call.method])
        {
            Log(LDEBUG, @"connectedPeripherals: %lu", self.connectedPeripherals.count);
            if (self.connectedPeripherals.count == 0) {
                Log(LDEBUG, @"Hot Restart: complete");
                [self.knownPeripherals removeAllObjects];
            }
            result(@(self.connectedPeripherals.count));
            return;
        }
        else if ([@"setLogLevel" isEqualToString:call.method])
        {
            NSNumber *idx = [call arguments];
            _logLevel = (LogLevel)[idx integerValue];
            result(@YES);
            return;
        }
        else if ([@"isSupported" isEqualToString:call.method])
        {
            result(self.centralManager != nil ? @(YES) : @(NO));
        }
        else if ([@"getAdapterName" isEqualToString:call.method])
        {
    #if TARGET_OS_IOS
            result([[UIDevice currentDevice] name]);
    #else // MacOS
            // TODO: support this via hostname?
            result(@"Mac Bluetooth Adapter");
    #endif
        }
        if ([@"getAdapterState" isEqualToString:call.method])
        {
            // get state
            int adapterState = 0; // BmAdapterStateEnum.unknown
            if (self->_centralManager) {
                adapterState = [self bmAdapterStateEnum:self->_centralManager.state];    
            }

            // See BmBluetoothAdapterState
            NSDictionary* response = @{
                @"adapter_state" : @(adapterState),
            };

            result(response);
        }
        else if([@"turnOn" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"turnOn" 
                                    message:@"iOS does not support turning on bluetooth"
                                    details:NULL]);
        }
        else if([@"turnOff" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"turnOff" 
                                    message:@"iOS does not support turning off bluetooth"
                                    details:NULL]);
        }
        else if ([@"startScan" isEqualToString:call.method])
        {
            // See BmScanSettings
            NSDictionary *args = (NSDictionary*) call.arguments;
            NSArray   *withServices    = args[@"with_services"];
            NSNumber  *continuousUpdates = args[@"continuous_updates"];

            // check adapter state
            if ([self isAdapterOn] == false) {
                NSString* s = @"bluetooth must be turned on";
                result([FlutterError errorWithCode:@"startScan" message:s details:NULL]);
                return;
            }

            // remember this for later
            self.scanFilters = args;

            // allowDuplicates?
            NSMutableDictionary<NSString *, id> *scanOpts = [NSMutableDictionary new];
            if ([continuousUpdates boolValue]) {
                [scanOpts setObject:[NSNumber numberWithBool:YES] forKey:CBCentralManagerScanOptionAllowDuplicatesKey];
            }

            // services filter
            NSArray *services = [NSArray array];
            for (int i = 0; i < [withServices count]; i++) {
                NSString *uuid = withServices[i];
                services = [services arrayByAddingObject:[CBUUID UUIDWithString:uuid]];
            }

            // clear counts
            [self.scanCounts removeAllObjects];

            // start scanning
            [self->_centralManager scanForPeripheralsWithServices:services options:scanOpts];

            result(@YES);
        }
        else if ([@"stopScan" isEqualToString:call.method])
        {
            [self->_centralManager stopScan];
            result(@YES);
        }
        else if ([@"getSystemDevices" isEqualToString:call.method])
        {
            // Cannot pass blank UUID list for security reasons.
            // Assume all devices have the Generic Access service 0x1800
            CBUUID* gasUuid = [CBUUID UUIDWithString:@"1800"];

            // this returns devices connected by *any* app
            NSArray *periphs = [self->_centralManager retrieveConnectedPeripheralsWithServices:@[gasUuid]];

            // Devices
            NSMutableArray *deviceProtos = [NSMutableArray new];
            for (CBPeripheral *p in periphs) {
                [deviceProtos addObject:[self bmBluetoothDevice:p]];
            }

            // See BmDevicesList
            NSDictionary* response = @{
                @"devices": deviceProtos,
            };

            result(response);
        }
        else if ([@"connect" isEqualToString:call.method])
        {
            // See BmConnectRequest
            NSDictionary* args = (NSDictionary*)call.arguments;
            NSString  *remoteId       = args[@"remote_id"];
            NSNumber  *autoConnect    = args[@"auto_connect"];

            // check adapter state
            if ([self isAdapterOn] == false) {
                NSString* s = @"bluetooth must be turned on";
                result([FlutterError errorWithCode:@"connect" message:s details:NULL]);
                return;
            }

            // already connected?
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral != nil) {
                Log(LDEBUG, @"already connected");
                result(@NO); // no work to do
                return;
            }

            // parse
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:remoteId];
            if (uuid == nil)
            {
                result([FlutterError errorWithCode:@"connect" message:@"invalid remoteId" details:remoteId]);
                return;
            }

            // check the devices iOS knowns about
            NSArray<CBPeripheral *> *peripherals = [_centralManager retrievePeripheralsWithIdentifiers:@[uuid]];
            for (CBPeripheral *p in peripherals)
            {
                if ([[p.identifier UUIDString] isEqualToString:remoteId])
                {
                    peripheral = p;
                    break;
                }
            }
            if (peripheral == nil)
            {
                result([FlutterError errorWithCode:@"connect" message:@"Peripheral not found" details:remoteId]);
                return;
            }

            // we must keep a strong reference to any CBPeripheral before we connect to it.
            // Why? CoreBluetooth does not keep strong references and will warn about API MISUSE and weak ptrs.
            [self.knownPeripherals setObject:peripheral forKey:remoteId];

            // set ourself as delegate
            peripheral.delegate = self;

            // options
            NSMutableDictionary *options = [[NSMutableDictionary alloc] init];
            if (@available(iOS 17, *)) {
                // note: use CBConnectPeripheralOptionEnableAutoReconnect constant
                // when iOS 17 is more widely available
                [options setObject:autoConnect forKey:@"kCBConnectOptionEnableAutoReconnect"];
            } 

            [_centralManager connectPeripheral:peripheral options:options];

            // add to currently connecting peripherals
            [self.currentlyConnectingPeripherals setObject:peripheral forKey:remoteId];
            
            result(@YES);
        }
        else if ([@"disconnect" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            // already disconnected?
            CBPeripheral *peripheral = nil;
            if (peripheral == nil) {
                Log(LDEBUG, @"disconnect: canceling connection in progress");
                peripheral = [self.currentlyConnectingPeripherals objectForKey:remoteId];
            }
            if (peripheral == nil) {
                peripheral = [self getConnectedPeripheral:remoteId];
            }
            if (peripheral == nil) {
                Log(LDEBUG, @"already disconnected");
                result(@NO); // no work to do
                return;
            }

            [_centralManager cancelPeripheralConnection:peripheral];
            
            result(@YES);
        }
        else if ([@"discoverServices" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            // Find peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"discoverServices" message:s details:remoteId]);
                return;
            }

            // Clear helper arrays
            [_servicesThatNeedDiscovered removeAllObjects];
            [_characteristicsThatNeedDiscovered removeAllObjects];

            // start discovery
            [peripheral discoverServices:nil];

            result(@YES);
        }
        else if ([@"readCharacteristic" isEqualToString:call.method])
        {
            // See BmReadCharacteristicRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];

            // Find peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"readCharacteristic" message:s details:remoteId]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"readCharacteristic" message:error.localizedDescription details:NULL]);
                return;
            }

            // check readable
            if ((characteristic.properties & CBCharacteristicPropertyRead) == 0) {
                NSString* s = @"The READ property is not supported by this BLE characteristic";
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                return;
            }

            // Trigger a read
            [peripheral readValueForCharacteristic:characteristic];

            result(@YES);
        }
        else if ([@"writeCharacteristic" isEqualToString:call.method])
        {
            // See BmWriteCharacteristicRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];
            NSNumber  *writeTypeNumber      = args[@"write_type"];
            NSNumber  *allowLongWrite       = args[@"allow_long_write"];
            NSString  *value                = args[@"value"];
            
            // Find peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:remoteId]);
                return;
            }

            // Get correct write type
            CBCharacteristicWriteType writeType =
                ([writeTypeNumber intValue] == 0
                    ? CBCharacteristicWriteWithResponse
                    : CBCharacteristicWriteWithoutResponse);

            // check maximum payload
            int maxLen = [self getMaxPayload:peripheral forType:writeType allowLongWrite:[allowLongWrite boolValue]];
            int dataLen = (int) [self convertHexToData:value].length;
            if (dataLen > maxLen) {
                NSString* t = [writeTypeNumber intValue] == 0 ? @"withResponse" : @"withoutResponse";
                NSString* a = [allowLongWrite boolValue] ? @", allowLongWrite" : @", noLongWrite";
                NSString* b = [writeTypeNumber intValue] == 0 ? a : @"";
                NSString* f = @"data longer than allowed. dataLen: %d > max: %d (%@%@)";
                NSString* s = [NSString stringWithFormat:f, dataLen, maxLen, t, b];
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                return;
            }

            // device not ready?
            if (writeType == CBCharacteristicWriteWithoutResponse && !peripheral.canSendWriteWithoutResponse) {
                // canSendWriteWithoutResponse is the current readiness of the peripheral to accept more write requests.
                NSString* s = @"canSendWriteWithoutResponse is false. you must slow down";
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                return;
            } 

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"writeCharacteristic" message:error.localizedDescription details:NULL]);
                return;
            }

            // check writeable
            if(writeType == CBCharacteristicWriteWithoutResponse) {
                if ((characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) == 0) {
                    NSString* s = @"The WRITE_NO_RESPONSE property is not supported by this BLE characteristic";
                    result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                    return;
                }
            } else {
                if ((characteristic.properties & CBCharacteristicPropertyWrite) == 0) {
                    NSString* s = @"The WRITE property is not supported by this BLE characteristic";
                    result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                    return;
                }
            }

            // remember the data we are writing
            NSString *key = [NSString stringWithFormat:@"%@:%@:%@", remoteId, serviceUuid, characteristicUuid];
            [self.writeChrs setObject:value forKey:key];
                  
            // Write to characteristic
            [peripheral writeValue:[self convertHexToData:value] forCharacteristic:characteristic type:writeType];

            // remember the most recent write withoutResponse
            if (writeType == CBCharacteristicWriteWithoutResponse) {
                [self.didWriteWithoutResponse setObject:args forKey:remoteId];
            }

            result(@YES);
        }
        else if ([@"readDescriptor" isEqualToString:call.method])
        {
            // See BmReadDescriptorRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *descriptorUuid       = args[@"descriptor_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];

            // Find peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"readDescriptor" message:s details:remoteId]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"readDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            // Find descriptor
            CBDescriptor *descriptor = [self locateDescriptor:descriptorUuid characteristic:characteristic error:&error];
            if (descriptor == nil) {
                result([FlutterError errorWithCode:@"readDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            [peripheral readValueForDescriptor:descriptor];

            result(@YES);
        }
        else if ([@"writeDescriptor" isEqualToString:call.method])
        {
            // See BmWriteDescriptorRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *descriptorUuid       = args[@"descriptor_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];
            NSString  *value                = args[@"value"];

            // Find peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"writeDescriptor" message:s details:remoteId]);
                return;
            }

            // check mtu
            int mtu = (int) [self getMtu:peripheral];
            int dataLen = (int) [self convertHexToData:value].length;
            if ((mtu-3) < dataLen) {
                NSString* f = @"data is longer than MTU allows. dataLen: %d > maxDataLen: %d";
                NSString* s = [NSString stringWithFormat:f, dataLen, (mtu-3)];
                result([FlutterError errorWithCode:@"writeDescriptor" message:s details:NULL]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"writeDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            // Find descriptor
            CBDescriptor *descriptor = [self locateDescriptor:descriptorUuid characteristic:characteristic error:&error];
            if (descriptor == nil) {
                result([FlutterError errorWithCode:@"writeDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            // remember the data we are writing
            NSString *key = [NSString stringWithFormat:@"%@:%@:%@:%@", remoteId, serviceUuid, characteristicUuid, descriptorUuid];
            [self.writeDescs setObject:value forKey:key];

            // Write descriptor
            [peripheral writeValue:[self convertHexToData:value] forDescriptor:descriptor];

            result(@YES);
        }
        else if ([@"setNotifyValue" isEqualToString:call.method])
        {
            // See BmSetNotifyValueRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString   *remoteId              = args[@"remote_id"];
            NSString   *serviceUuid           = args[@"service_uuid"];
            NSString   *secondaryServiceUuid  = args[@"secondary_service_uuid"];
            NSString   *characteristicUuid    = args[@"characteristic_uuid"];
            NSNumber   *enable                = args[@"enable"];

            // Find peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"setNotifyValue" message:s details:remoteId]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"setNotifyValue" message:error.localizedDescription details:NULL]);
                return;
            }

            // check notify-able
            bool canNotify = (characteristic.properties & CBCharacteristicPropertyNotify) != 0;
            bool canIndicate = (characteristic.properties & CBCharacteristicPropertyIndicate) != 0;
            if(!canIndicate && !canNotify) {
                NSString* s = @"neither NOTIFY nor INDICATE properties are supported by this BLE characteristic";
                result([FlutterError errorWithCode:@"setNotifyValue" message:s details:NULL]);
                return;
            }

            // Check that CCCD is found, this is necessary for subscribing
            CBDescriptor *descriptor = [self locateDescriptor:CCCD characteristic:characteristic error:nil];
            if (descriptor == nil) {
                Log(LWARNING, @"Warning: CCCD descriptor for characteristic not found: %@", characteristicUuid);
            }

            // Set notification value
            [peripheral setNotifyValue:[enable boolValue] forCharacteristic:characteristic];
            
            result(@YES);
        }
        else if ([@"requestMtu" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"requestMtu"
                                    message:@"iOS does not allow mtu requests to the peripheral"
                                    details:NULL]);
        }
        else if ([@"readRssi" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            // get peripheral
            CBPeripheral *peripheral = [self getConnectedPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"device is disconnected";
                result([FlutterError errorWithCode:@"readRssi" message:s details:remoteId]);
                return;
            }

            [peripheral readRSSI];

            result(@YES);
        }
        else if([@"requestConnectionPriority" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"requestConnectionPriority" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else if([@"getPhySupport" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"getPhySupport" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else if([@"setPreferredPhy" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"setPreferredPhy" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else if([@"getBondedDevices" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"getBondedDevices" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else if([@"createBond" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"setPreferredPhy" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else if([@"removeBond" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"removeBond" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else if([@"clearGattCache" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"clearGattCache" 
                                    message:@"android only"
                                    details:NULL]);
        }
        else
        {
            result(FlutterMethodNotImplemented);
        }
    }
    @catch (NSException *e)
    {
        NSString *stackTrace = [[e callStackSymbols] componentsJoinedByString:@"\n"];
        NSDictionary *details = @{@"stackTrace": stackTrace};
        result([FlutterError errorWithCode:@"iosException" message:[e reason] details:details]);
    }
}

//////////////////////////////////////////////////////////////////////
// ██████   ██████   ██  ██    ██   █████   ████████  ███████ 
// ██   ██  ██   ██  ██  ██    ██  ██   ██     ██     ██      
// ██████   ██████   ██  ██    ██  ███████     ██     █████   
// ██       ██   ██  ██   ██  ██   ██   ██     ██     ██      
// ██       ██   ██  ██    ████    ██   ██     ██     ███████
//
// ██    ██  ████████  ██  ██       ███████ 
// ██    ██     ██     ██  ██       ██      
// ██    ██     ██     ██  ██       ███████ 
// ██    ██     ██     ██  ██            ██ 
//  ██████      ██     ██  ███████  ███████ 

- (CBPeripheral *)getConnectedPeripheral:(NSString *)remoteId
{
    return [self.connectedPeripherals objectForKey:remoteId];
}

- (CBCharacteristic *)locateCharacteristic:(NSString *)characteristicId
                                peripheral:(CBPeripheral *)peripheral
                                 serviceId:(NSString *)serviceId
                        secondaryServiceId:(NSString *)secondaryServiceId
                                     error:(NSError **)error
{
    // primary
    CBService *primaryService = [self getServiceFromArray:serviceId array:[peripheral services]];
    if (primaryService == nil || [primaryService isPrimary] == false)
    {
        NSString* s = [NSString stringWithFormat:@"service not found '%@'", serviceId];
        NSDictionary* d = @{NSLocalizedDescriptionKey : s};
        *error = [NSError errorWithDomain:@"flutterBluePlus" code:1000 userInfo:d];
        return nil;
    }

    // secondary
    CBService *secondaryService;
    if (secondaryServiceId && (NSNull*) secondaryServiceId != [NSNull null] && secondaryServiceId.length)
    {
        secondaryService = [self getServiceFromArray:secondaryServiceId array:[primaryService includedServices]];
        if (error && !secondaryService) {
            NSString* s = [NSString stringWithFormat:@"secondaryService not found '%@'", secondaryServiceId];
            NSDictionary* d = @{NSLocalizedDescriptionKey : s};
            *error = [NSError errorWithDomain:@"flutterBluePlus" code:1001 userInfo:d];
            return nil;
        }
    }

    // which service?
    CBService *service = (secondaryService != nil) ? secondaryService : primaryService;

    // characteristic
    CBCharacteristic *characteristic = [self getCharacteristicFromArray:characteristicId array:[service characteristics]];
    if (characteristic == nil)
    {
        NSString* format = @"characteristic not found in service (chr: '%@', svc: '%@')";
        NSString* s = [NSString stringWithFormat:format, characteristicId, serviceId];
        NSDictionary* d = @{NSLocalizedDescriptionKey : s};
        *error = [NSError errorWithDomain:@"flutterBluePlus" code:1002 userInfo:d];
        return nil;
    }
    return characteristic;
}


- (CBDescriptor *)locateDescriptor:(NSString *)descriptorId characteristic:(CBCharacteristic *)characteristic error:(NSError**)error
{
    CBDescriptor *descriptor = [self getDescriptorFromArray:descriptorId array:[characteristic descriptors]];
    if (descriptor == nil && error != nil)
    {
        NSString* format = @"descriptor not found in characteristic (desc: '%@', chr: '%@')";
        NSString* s = [NSString stringWithFormat:format, descriptorId, [characteristic.UUID uuidStr]];
        NSDictionary* d = @{NSLocalizedDescriptionKey : s};
        *error = [NSError errorWithDomain:@"flutterBluePlus" code:1002 userInfo:d];
        return nil;
    }
    return descriptor;
}

- (CBService *)getServiceFromArray:(NSString *)uuid array:(NSArray<CBService *> *)array
{
    for (CBService *s in array)
    {
        if ([[s.UUID uuidStr] isEqualToString:uuid])
        {
            return s;
        }
    }
    return nil;
}

- (CBCharacteristic *)getCharacteristicFromArray:(NSString *)uuid array:(NSArray<CBCharacteristic *> *)array
{
    for (CBCharacteristic *c in array)
    {
        if ([[c.UUID uuidStr] isEqualToString:uuid])
        {
            return c;
        }
    }
    return nil;
}

- (CBDescriptor *)getDescriptorFromArray:(NSString *)uuid array:(NSArray<CBDescriptor *> *)array
{
    for (CBDescriptor *d in array)
    {
        if ([[d.UUID uuidStr] isEqualToString:uuid])
        {
            return d;
        }
    }
    return nil;
}

- (void)disconnectAllDevices:(NSString*)func
{
    Log(LDEBUG, @"disconnectAllDevices(%@)", func);

    // request disconnections
    for (NSString *key in self.connectedPeripherals)
    {
        CBPeripheral *peripheral = [self.connectedPeripherals objectForKey:key];

        Log(LDEBUG, @"calling disconnect: %@", key);

        if ([func isEqualToString:@"adapterTurnOff"]) {
            // inexplicably, iOS does not call 'didDisconnectPeripheral' when
            // the adapter is turned off, so we must send these responses manually
            
            // Note: when the adapter is turned off, it is an 'api misuse'
            // to call cancelPeripheralConnection. It is implied.

            // See BmConnectionStateResponse
            NSDictionary *result = @{
                @"remote_id":                [[peripheral identifier] UUIDString],
                @"connection_state":         @([self bmConnectionStateEnum:CBPeripheralStateDisconnected]),
                @"disconnect_reason_code":   @(1573878), // just a random value, could be anything.
                @"disconnect_reason_string": @"Bluetooth turned off",
            };

            // Send connection state
            [_methodChannel invokeMethod:@"OnConnectionStateChanged" arguments:result];
        } 
        
        if ([func isEqualToString:@"flutterHotRestart"] && [self isAdapterOn]) {
            // request disconnection
            [self.centralManager cancelPeripheralConnection:peripheral];
        }
    }

    // normally connectedPeripherals will be updated by 'didDisconnectPeripheral',
    // but iOS does not call 'didDisconnectPeripheral' when the
    // adapter is turned off, so we must clear it ourself
    if ([func isEqualToString:@"adapterTurnOff"]) {
        [self.connectedPeripherals removeAllObjects];
        [self.currentlyConnectingPeripherals removeAllObjects];
    }

    // note: we do *not* clear self.knownPeripherals
    // Otherwise the peripheral would not have any strong references 
    // and would be garbage collected, making the didDisconnectPeripheral
    // callback not called

    [self.servicesThatNeedDiscovered removeAllObjects];
    [self.characteristicsThatNeedDiscovered removeAllObjects];
    [self.didWriteWithoutResponse removeAllObjects];
    [self.peripheralMtu removeAllObjects];
    [self.writeChrs removeAllObjects];
    [self.writeDescs removeAllObjects];
}

////////////////////////////////////
// ███    ███ ████████ ██    ██ 
// ████  ████    ██    ██    ██ 
// ██ ████ ██    ██    ██    ██ 
// ██  ██  ██    ██    ██    ██ 
// ██      ██    ██     ██████  

// in iOS, mtu is negotatiated once automatically sometime after the
// the connection process, but there is no platform callback for it.
- (void)checkForMtuChangesCallback
{
    for (NSString *key in self.connectedPeripherals) {

        CBPeripheral *peripheral = [self.connectedPeripherals objectForKey:key];

        int curMtu = (int) [self getMtu:peripheral];

        NSNumber* prevMtu = (NSNumber*) [self.peripheralMtu objectForKey:peripheral];

        // mtu changed?
        if (prevMtu == nil || [prevMtu intValue] != curMtu) {

            // remember new mtu value
            [self.peripheralMtu setObject:@(curMtu) forKey:peripheral];

            NSString* remoteId = [[peripheral identifier] UUIDString];

            // See BmMtuChangedResponse
            NSDictionary* mtuChanged = @{
                @"remote_id" :      remoteId,
                @"mtu":             @(curMtu),
                @"success":         @(1),
                @"error_string":    @"success",
                @"error_code":      @(0),
            };

            // send mtu value
            [_methodChannel invokeMethod:@"OnMtuChanged" arguments:mtuChanged];
        }
    }
}

/////////////////////////////////////////////////////////////////////////////////////
//  ██████  ██████    ██████  ███████  ███    ██  ████████  ██████    █████  ██      
// ██       ██   ██  ██       ██       ████   ██     ██     ██   ██  ██   ██ ██      
// ██       ██████   ██       █████    ██ ██  ██     ██     ██████   ███████ ██      
// ██       ██   ██  ██       ██       ██  ██ ██     ██     ██   ██  ██   ██ ██      
//  ██████  ██████    ██████  ███████  ██   ████     ██     ██   ██  ██   ██ ███████ 
//                                                                                                                                          
// ███    ███   █████   ███    ██   █████    ██████   ███████  ██████               
// ████  ████  ██   ██  ████   ██  ██   ██  ██        ██       ██   ██              
// ██ ████ ██  ███████  ██ ██  ██  ███████  ██   ███  █████    ██████               
// ██  ██  ██  ██   ██  ██  ██ ██  ██   ██  ██    ██  ██       ██   ██              
// ██      ██  ██   ██  ██   ████  ██   ██   ██████   ███████  ██   ██              
//                                                                                                                                                   
// ██████   ███████  ██       ███████   ██████    █████   ████████  ███████          
// ██   ██  ██       ██       ██       ██        ██   ██     ██     ██               
// ██   ██  █████    ██       █████    ██   ███  ███████     ██     █████            
// ██   ██  ██       ██       ██       ██    ██  ██   ██     ██     ██               
// ██████   ███████  ███████  ███████   ██████   ██   ██     ██     ███████ 

- (void)centralManagerDidUpdateState:(nonnull CBCentralManager *)central
{
    Log(LDEBUG, @"centralManagerDidUpdateState %@", [self cbManagerStateString:self->_centralManager.state]);

    // was the adapter turned off?
    if (self->_centralManager.state != CBManagerStatePoweredOn) {
        [self disconnectAllDevices:@"adapterTurnOff"];
    }

    int adapterState = [self bmAdapterStateEnum:self->_centralManager.state];

    // See BmBluetoothAdapterState
    NSDictionary* response = @{
        @"adapter_state" : @(adapterState),
    };

    [_methodChannel invokeMethod:@"OnAdapterStateChanged" arguments:response];
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI
{
    Log(LVERBOSE, @"centralManager didDiscoverPeripheral");

    NSString* remoteId = [[peripheral identifier] UUIDString];
    
    // add to known peripherals
    [self.knownPeripherals setObject:peripheral forKey:remoteId];

    // increment scan count
    NSInteger count = [self scanCountIncrement:remoteId];

    // advertising data
    NSString *advName = advertisementData[CBAdvertisementDataLocalNameKey];
    NSData *advMsd = advertisementData[CBAdvertisementDataManufacturerDataKey];
    NSDictionary* advSd = advertisementData[CBAdvertisementDataServiceDataKey];

    // divisor
    if (count % [self.scanFilters[@"continuous_divisor"] integerValue] != 0) {
        return;
    }

    // remoteIds
    if (![self filterRemoteIds:self.scanFilters[@"with_remote_ids"] target:remoteId]) {
        return;
    }

    // names
    if (![self filterNames:self.scanFilters[@"with_names"] target:advName]) {
        return;
    }

    // keywords
    if (![self filterKeywords:self.scanFilters[@"with_keywords"] target:advName]) {
        return;
    }

    // msd
    if (![self filterMsd:self.scanFilters[@"with_msd"] msd:advMsd]) {
        return;
    }

    // service data
    if (![self filterServiceData:self.scanFilters[@"with_service_data"] sd:advSd]) {
        return;
    }

    // See BmScanResponse
    NSDictionary *response = @{
        @"advertisements": @[[self bmScanAdvertisement:remoteId advertisementData:advertisementData RSSI:RSSI]],
    };

    [_methodChannel invokeMethod:@"OnScanResponse" arguments:response];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral
{
    Log(LDEBUG, @"didConnectPeripheral");

    NSString* remoteId = [[peripheral identifier] UUIDString];

    // remember the connected peripherals of *this app*
    [self.connectedPeripherals setObject:peripheral forKey:remoteId];

    // remove from currently connecting peripherals
    [self.currentlyConnectingPeripherals removeObjectForKey:remoteId];

    // Register self as delegate for peripheral
    peripheral.delegate = self;

    // See BmConnectionStateResponse
    NSDictionary *result = @{
        @"remote_id":                remoteId,
        @"connection_state":         @([self bmConnectionStateEnum:peripheral.state]),
        @"disconnect_reason_code":   [NSNull null],
        @"disconnect_reason_string": [NSNull null],
    };

    // Send connection state
    [_methodChannel invokeMethod:@"OnConnectionStateChanged" arguments:result];
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error
{
    if (error) {
        // error contains the reason for the unexpected disconnection
        Log(LERROR, @"didDisconnectPeripheral: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didDisconnectPeripheral");
    }

    NSString* remoteId = [[peripheral identifier] UUIDString];

    // remember the connected peripherals of *this app*
    [self.connectedPeripherals removeObjectForKey:remoteId];

    // remove from currently connecting peripherals
    [self.currentlyConnectingPeripherals removeObjectForKey:remoteId];

    // clear negotiated mtu
    [self.peripheralMtu removeObjectForKey:peripheral];

    // Unregister self as delegate for peripheral, not working #42
    peripheral.delegate = nil;

    // See BmConnectionStateResponse
    NSDictionary *result = @{
        @"remote_id":                remoteId,
        @"connection_state":         @([self bmConnectionStateEnum:peripheral.state]),
        @"disconnect_reason_code":   error ? @(error.code) : @(23789258),
        @"disconnect_reason_string": error ? [error localizedDescription] : @("connection canceled"),
    };

    // Send connection state
    [_methodChannel invokeMethod:@"OnConnectionStateChanged" arguments:result];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error
{
    if (error) {
        // error contains the reason for the connection failure
        Log(LERROR, @"didFailToConnectPeripheral: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didFailToConnectPeripheral");
    }

    NSString* remoteId = [[peripheral identifier] UUIDString];

    // remove from currently connecting peripherals
    [self.currentlyConnectingPeripherals removeObjectForKey:remoteId];

    // See BmConnectionStateResponse
    NSDictionary *result = @{
        @"remote_id":                [[peripheral identifier] UUIDString],
        @"connection_state":         @([self bmConnectionStateEnum:peripheral.state]),
        @"disconnect_reason_code":   error ? @(error.code) : [NSNull null], 
        @"disconnect_reason_string": error ? [error localizedDescription] : [NSNull null],
    };

    // Send connection state
    [_methodChannel invokeMethod:@"OnConnectionStateChanged" arguments:result];
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////
//  ██████  ██████   ██████   ███████  ██████   ██  ██████   ██   ██  ███████  ██████    █████   ██      
// ██       ██   ██  ██   ██  ██       ██   ██  ██  ██   ██  ██   ██  ██       ██   ██  ██   ██  ██      
// ██       ██████   ██████   █████    ██████   ██  ██████   ███████  █████    ██████   ███████  ██      
// ██       ██   ██  ██       ██       ██   ██  ██  ██       ██   ██  ██       ██   ██  ██   ██  ██      
//  ██████  ██████   ██       ███████  ██   ██  ██  ██       ██   ██  ███████  ██   ██  ██   ██  ███████
//
// ██████   ███████  ██       ███████   ██████    █████   ████████  ███████          
// ██   ██  ██       ██       ██       ██        ██   ██     ██     ██               
// ██   ██  █████    ██       █████    ██   ███  ███████     ██     █████            
// ██   ██  ██       ██       ██       ██    ██  ██   ██     ██     ██               
// ██████   ███████  ███████  ███████   ██████   ██   ██     ██     ███████ 

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverServices:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didDiscoverServices: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didDiscoverServices");
    }

    // discover characteristics and secondary services
    [_servicesThatNeedDiscovered addObjectsFromArray:peripheral.services];
    for (CBService *s in [peripheral services]) {
        Log(LDEBUG, @"Found service: %@", [s.UUID UUIDString]);
        [peripheral discoverCharacteristics:nil forService:s];
        // Secondary services in the future (#8)
        // [peripheral discoverIncludedServices:nil forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service
                                   error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didDiscoverCharacteristicsForService: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didDiscoverCharacteristicsForService");
    }

    // Loop through and discover descriptors for characteristics
    [_servicesThatNeedDiscovered removeObject:service];
    [_characteristicsThatNeedDiscovered addObjectsFromArray:service.characteristics];
    for (CBCharacteristic *c in [service characteristics])
    {
        [peripheral discoverDescriptorsForCharacteristic:c];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic
                                      error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didDiscoverDescriptorsForCharacteristic: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didDiscoverDescriptorsForCharacteristic");
    }

    [_characteristicsThatNeedDiscovered removeObject:characteristic];
    if (_servicesThatNeedDiscovered.count > 0 || _characteristicsThatNeedDiscovered.count > 0)
    {
        // Still discovering
        return;
    }

    // Services
    NSMutableArray *services = [NSMutableArray new];
    for (CBService *s in [peripheral services])
    {
        [services addObject:[self bmBluetoothService:peripheral service:s]];
    }

    // See BmDiscoverServicesResult
    NSDictionary* response = @{
        @"remote_id":       [peripheral.identifier UUIDString],
        @"services":        services,
        @"success":         error == nil ? @(1) : @(0),
        @"error_string":    error ? [error localizedDescription] : @"success",
        @"error_code":      error ? @(error.code) : @(0),
    };

    // Send updated tree
    [_methodChannel invokeMethod:@"OnDiscoveredServices" arguments:response];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverIncludedServicesForService:(CBService *)service
                                    error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didDiscoverIncludedServicesForService: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didDiscoverIncludedServicesForService");
    }

    // Loop through and discover characteristics for secondary services
    for (CBService *ss in [service includedServices])
    {
        [peripheral discoverCharacteristics:nil forService:ss];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                              error:(NSError *)error
{
    // this callback is called for notifications as well as manual reads
    if (error) {
        Log(LERROR, @"didUpdateValueForCharacteristic: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didUpdateValueForCharacteristic %@", [peripheral.identifier UUIDString]);
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // See BmCharacteristicData
    NSDictionary* result = @{
        @"remote_id":               [peripheral.identifier UUIDString],
        @"service_uuid":            [pair.primary.UUID uuidStr],
        @"secondary_service_uuid":  pair.secondary ? [pair.secondary.UUID uuidStr] : [NSNull null],
        @"characteristic_uuid":     [characteristic.UUID uuidStr],
        @"value":                   [self convertDataToHex:characteristic.value],
        @"success":                 error == nil ? @(1) : @(0),
        @"error_string":            error ? [error localizedDescription] : @"success",
        @"error_code":              error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnCharacteristicReceived" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
                             error:(NSError *)error
{
    // Note:
    //  - this callback is only called for writeWithResponse
    if (error) {
        Log(LERROR, @"didWriteValueForCharacteristic: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didWriteValueForCharacteristic");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // for convenience
    NSString *remoteId = [peripheral.identifier UUIDString];
    NSString *serviceUuid = [pair.primary.UUID uuidStr];
    NSString *secondaryServiceUuid = pair.secondary ? [pair.secondary.UUID uuidStr] : nil;
    NSString *characteristicUuid = [characteristic.UUID uuidStr];

    // what data did we write?
    NSString *key = [NSString stringWithFormat:@"%@:%@:%@", remoteId, serviceUuid, characteristicUuid];
    NSString *value = self.writeChrs[key] ? self.writeChrs[key] : @"";
    [self.writeChrs removeObjectForKey:key];

    // See BmCharacteristicData
    NSDictionary* result = @{
        @"remote_id":               remoteId,
        @"service_uuid":            serviceUuid,
        @"secondary_service_uuid":  pair.secondary ? secondaryServiceUuid : [NSNull null],
        @"characteristic_uuid":     characteristicUuid,
        @"value":                   value,
        @"success":                 @(error == nil),
        @"error_string":            error ? [error localizedDescription] : @"success",
        @"error_code":              error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnCharacteristicWritten" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
                                          error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didUpdateNotificationStateForCharacteristic: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didUpdateNotificationStateForCharacteristic");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // Oddly iOS does not update the CCCD descriptors when didUpdateNotificationState is called. 
    // So instead of using characteristic.descriptors we have to manually recreate the
    // CCCD descriptor using isNotifying & characteristic.properties
    int value = 0;
    if(characteristic.isNotifying) {
        // in iOS, if a characteristic supports both indications and notifications, 
        // then CoreBluetooth will default to indications
        bool supportsNotify = (characteristic.properties & CBCharacteristicPropertyNotify) != 0;
        bool supportsIndicate = (characteristic.properties & CBCharacteristicPropertyIndicate) != 0;
        if (characteristic.isNotifying && supportsIndicate) {value = 2;} // '2' comes from the CCCD BLE spec
        if (characteristic.isNotifying && supportsNotify) {value = 1;} // '1' comes from the CCCD BLE spec
    }
    
    // See BmDescriptorData
    NSDictionary* result = @{
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID uuidStr],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID uuidStr] : [NSNull null],
        @"characteristic_uuid":    [characteristic.UUID uuidStr],
        @"descriptor_uuid":        CCCD,
        @"value":                  [self convertDataToHex:[NSData dataWithBytes:&value length:sizeof(value)]],
        @"success":                @(error == nil),
        @"error_string":           error ? [error localizedDescription] : @"success",
        @"error_code":             error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnDescriptorWritten" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForDescriptor:(CBDescriptor *)descriptor
                          error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didUpdateValueForDescriptor: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didUpdateValueForDescriptor");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:descriptor.characteristic];

    NSData* data = [self descriptorToData:descriptor];
    
    // See BmDescriptorData
    NSDictionary* result = @{
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID uuidStr],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID uuidStr] : [NSNull null],
        @"characteristic_uuid":    [descriptor.characteristic.UUID uuidStr],
        @"descriptor_uuid":        [descriptor.UUID uuidStr],
        @"value":                  [self convertDataToHex:data],
        @"success":                @(error == nil),
        @"error_string":           error ? [error localizedDescription] : @"success",
        @"error_code":             error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnDescriptorRead" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didWriteValueForDescriptor:(CBDescriptor *)descriptor
                         error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didWriteValueForDescriptor: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didWriteValueForDescriptor");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:descriptor.characteristic];

    // for convenience
    NSString *remoteId = [peripheral.identifier UUIDString];
    NSString *serviceUuid = [pair.primary.UUID uuidStr];
    NSString *secondaryServiceUuid = pair.secondary ? [pair.secondary.UUID uuidStr] : nil;
    NSString *characteristicUuid = [descriptor.characteristic.UUID uuidStr];
    NSString *descriptorUuid = [descriptor.UUID uuidStr];

    // what data did we write?
    NSString *key = [NSString stringWithFormat:@"%@:%@:%@:%@", remoteId, serviceUuid, characteristicUuid, descriptorUuid];
    NSString *value = self.writeChrs[key] ? self.writeChrs[key] : @"";
    [self.writeDescs removeObjectForKey:key];
    
    // See BmDescriptorData
    NSDictionary* result = @{
        @"remote_id":              remoteId,
        @"service_uuid":           serviceUuid,
        @"secondary_service_uuid": pair.secondary ? secondaryServiceUuid : [NSNull null],
        @"characteristic_uuid":    characteristicUuid,
        @"descriptor_uuid":        descriptorUuid,
        @"value":                  value,
        @"success":                @(error == nil),
        @"error_string":           error ? [error localizedDescription] : @"success",
        @"error_code":             error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnDescriptorWritten" arguments:result];
}

- (void)peripheralDidUpdateName:(CBPeripheral *)peripheral
{
    Log(LDEBUG, @"didUpdateName");

    // See BmNameChanged
    NSDictionary* result = @{
        @"remote_id":       [[peripheral identifier] UUIDString],
        @"name":        [peripheral name] ? [peripheral name] : [NSNull null],
    };

    [_methodChannel invokeMethod:@"OnNameChanged" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral 
    didModifyServices:(NSArray<CBService *> *)invalidatedServices
{
    Log(LDEBUG, @"didModifyServices");

    NSDictionary* result = [self bmBluetoothDevice:peripheral];

    [_methodChannel invokeMethod:@"OnServicesReset" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didReadRSSI:(NSNumber *)rssi error:(NSError *)error
{
    if (error) {
        Log(LERROR, @"didReadRSSI: [Error] %@", [error localizedDescription]);
    } else {
        Log(LDEBUG, @"didReadRSSI");
    }

    // See BmReadRssiResult
    NSDictionary* result = @{
        @"remote_id":       [peripheral.identifier UUIDString],
        @"rssi":            rssi,
        @"success":         @(error == nil),
        @"error_string":    error ? [error localizedDescription] : @"success",
        @"error_code":      error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnReadRssi" arguments:result];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral
{
    Log(LVERBOSE, @"peripheralIsReadyToSendWriteWithoutResponse");

    // peripheralIsReadyToSendWriteWithoutResponse is used to signal
    // when a 'writeWithoutResponse' request has completed. 
    // The dart code will wait for this signal, so that we don't
    // queue writes too fast, which iOS would then drop the packets.
    
    NSDictionary *request = [self.didWriteWithoutResponse objectForKey:[[peripheral identifier] UUIDString]];
    if (request == nil) {
        Log(LERROR, @"didWriteWithoutResponse is null");
        return;
    }
    
    // See BmWriteCharacteristicRequest
    NSString  *characteristicUuid   = request[@"characteristic_uuid"];
    NSString  *serviceUuid          = request[@"service_uuid"];
    NSString  *secondaryServiceUuid = request[@"secondary_service_uuid"];

    // Find characteristic
    NSError *error = nil;
    CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                       peripheral:peripheral
                                                        serviceId:serviceUuid
                                               secondaryServiceId:secondaryServiceUuid
                                                            error:&error];
    if (characteristic == nil) {
        Log(LERROR, @"Error: peripheralIsReadyToSendWriteWithoutResponse: %@", [error localizedDescription]);
        return;
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // See BmCharacteristicData
    NSDictionary* result = @{
        @"remote_id":               [peripheral.identifier UUIDString],
        @"service_uuid":            [pair.primary.UUID uuidStr],
        @"secondary_service_uuid":  pair.secondary ? [pair.secondary.UUID uuidStr] : [NSNull null],
        @"characteristic_uuid":     [characteristic.UUID uuidStr],
        @"value":                   [self convertDataToHex:characteristic.value],
        @"success":                 @(error == nil),
        @"error_string":            error ? [error localizedDescription] : @"success",
        @"error_code":              error ? @(error.code) : @(0),
    };

    [_methodChannel invokeMethod:@"OnCharacteristicWritten" arguments:result];
}

//////////////////////////////////////////////////////////////////////
// ███    ███  ███████   ██████      
// ████  ████  ██       ██           
// ██ ████ ██  ███████  ██   ███     
// ██  ██  ██       ██  ██    ██     
// ██      ██  ███████   ██████ 
//     
// ██   ██  ███████  ██       ██████   ███████  ██████   ███████ 
// ██   ██  ██       ██       ██   ██  ██       ██   ██  ██      
// ███████  █████    ██       ██████   █████    ██████   ███████ 
// ██   ██  ██       ██       ██       ██       ██   ██       ██ 
// ██   ██  ███████  ███████  ██       ███████  ██   ██  ███████ 

- (int)bmAdapterStateEnum:(CBManagerState)adapterState
{
    switch (adapterState)
    {
        case CBManagerStateUnknown:      return 0; // BmAdapterStateEnum.unknown
        case CBManagerStateUnsupported:  return 1; // BmAdapterStateEnum.unavailable
        case CBManagerStateUnauthorized: return 2; // BmAdapterStateEnum.unauthorized
        case CBManagerStateResetting:    return 3; // BmAdapterStateEnum.turningOn
        case CBManagerStatePoweredOn:    return 4; // BmAdapterStateEnum.on
        case CBManagerStatePoweredOff:   return 6; // BmAdapterStateEnum.off
        default:                         return 0; // BmAdapterStateEnum.unknown
    }
    return 0;
}

- (NSDictionary *)bmScanAdvertisement:(NSString*)remoteId
             advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                          RSSI:(NSNumber *)RSSI
{
    NSString     *advName        = advertisementData[CBAdvertisementDataLocalNameKey];
    NSNumber     *connectable    = advertisementData[CBAdvertisementDataIsConnectable];
    NSNumber     *txPower        = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    NSData       *manufData      = advertisementData[CBAdvertisementDataManufacturerDataKey];
    NSArray      *serviceUuids   = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    NSDictionary *serviceData    = advertisementData[CBAdvertisementDataServiceDataKey];

    // Manufacturer Data
    NSDictionary* manufDataB = nil;
    if (manufData != nil && manufData.length >= 2) {
        
        // first 2 bytes are manufacturerId
        unsigned short manufId = 0;
        [manufData getBytes:&manufId length:2];

        // trim off first 2 bytes
        NSData* trimmed = [manufData subdataWithRange:NSMakeRange(2, manufData.length - 2)];
        NSString* hex = [self convertDataToHex:trimmed];
        
        manufDataB = @{
            @(manufId): hex,
        };
    }
    
    // Service Uuids - convert from CBUUID's to UUID strings
    NSArray *serviceUuidsB = nil;
    if (serviceUuids != nil) {
        NSMutableArray *mutable = [[NSMutableArray alloc] init];
        for (CBUUID *uuid in serviceUuids) {
            [mutable addObject:[uuid uuidStr]];
        }
        serviceUuidsB = [mutable copy];
    }
    
    // Service Data - convert from CBUUID's to UUID strings
    NSDictionary *serviceDataB = nil;
    if (serviceData != nil)
    {
        NSMutableDictionary *mutable = [[NSMutableDictionary alloc] init];
        for (CBUUID *uuid in serviceData) {
            NSString* hex = [self convertDataToHex:serviceData[uuid]];
            [mutable setObject:hex forKey:[uuid uuidStr]];
        }
        serviceDataB = [mutable copy];
    }

    // platform name
    NSString* platformName = nil;
    if ([self.knownPeripherals objectForKey:remoteId] != nil) {
        CBPeripheral* peripheral = [self.knownPeripherals objectForKey:remoteId];
        platformName = peripheral.name;
    }

    // See BmScanAdvertisement
    // perf: only add keys if they exist
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    if (remoteId)              {map[@"remote_id"] = remoteId;}
    if (platformName)          {map[@"platform_name"] = platformName;}
    if (advName)               {map[@"adv_name"] = advName;}
    if (connectable.boolValue) {map[@"connectable"] = connectable;}
    if (txPower)               {map[@"tx_power_level"] = txPower;}
    if (manufDataB)            {map[@"manufacturer_data"] = manufDataB;}
    if (serviceUuidsB)         {map[@"service_uuids"] = serviceUuidsB;}
    if (serviceDataB)          {map[@"service_data"] = serviceDataB;}
    if (RSSI)                  {map[@"rssi"] = RSSI;}
    return map;
}

- (NSDictionary *)bmBluetoothDevice:(CBPeripheral *)peripheral
{
    return @{
        @"remote_id":       [[peripheral identifier] UUIDString],
        @"platform_name":   [peripheral name] ? [peripheral name] : [NSNull null],
    };
}

- (int)bmConnectionStateEnum:(CBPeripheralState)connectionState
{
    switch (connectionState)
    {
        case CBPeripheralStateDisconnected:  return 0; // BmConnectionStateEnum.disconnected
        case CBPeripheralStateConnected:     return 1; // BmConnectionStateEnum.connected
        default:                             return 0;
    }
}

- (NSDictionary *)bmBluetoothService:(CBPeripheral *)peripheral service:(CBService *)service
{
    // Characteristics
    NSMutableArray *characteristicProtos = [NSMutableArray new];
    for (CBCharacteristic *c in [service characteristics])
    {
        [characteristicProtos addObject:[self bmBluetoothCharacteristic:peripheral characteristic:c]];
    }

    // Included Services
    NSMutableArray *includedServicesProtos = [NSMutableArray new];
    for (CBService *included in [service includedServices])
    {
        // service includes itself?
        if ([included.UUID isEqual:service.UUID]) {
            continue; // skip, infinite recursion
        }
        [includedServicesProtos addObject:[self bmBluetoothService:peripheral service:included]];
    }

    // See BmBluetoothService
    return @{
        @"remote_id":           [peripheral.identifier UUIDString],
        @"service_uuid":        [service.UUID uuidStr],
        @"characteristics":     characteristicProtos,
        @"is_primary":          @([service isPrimary]),
        @"included_services":   includedServicesProtos,
    };
}

- (NSDictionary*)bmBluetoothCharacteristic:(CBPeripheral *)peripheral
                            characteristic:(CBCharacteristic *)characteristic
{
    // descriptors
    NSMutableArray *descriptors = [NSMutableArray new];
    for (CBDescriptor *d in [characteristic descriptors])
    {
        // See: BmBluetoothDescriptor
        NSDictionary* desc = @{
            @"remote_id":              [peripheral.identifier UUIDString],
            @"service_uuid":           [d.characteristic.service.UUID uuidStr],
            @"secondary_service_uuid": [NSNull null],
            @"characteristic_uuid":    [d.characteristic.UUID uuidStr],
            @"descriptor_uuid":        [d.UUID uuidStr],
        };

        [descriptors addObject:desc];
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    CBCharacteristicProperties props = characteristic.properties;

    // See: BmCharacteristicProperties
    NSDictionary* propsMap = @{
        @"broadcast":                    @((props & CBCharacteristicPropertyBroadcast) != 0),
        @"read":                         @((props & CBCharacteristicPropertyRead) != 0),
        @"write_without_response":       @((props & CBCharacteristicPropertyWriteWithoutResponse) != 0),
        @"write":                        @((props & CBCharacteristicPropertyWrite) != 0),
        @"notify":                       @((props & CBCharacteristicPropertyNotify) != 0),
        @"indicate":                     @((props & CBCharacteristicPropertyIndicate) != 0),
        @"authenticated_signed_writes":  @((props & CBCharacteristicPropertyAuthenticatedSignedWrites) != 0),
        @"extended_properties":          @((props & CBCharacteristicPropertyExtendedProperties) != 0),
        @"notify_encryption_required":   @((props & CBCharacteristicPropertyNotifyEncryptionRequired) != 0),
        @"indicate_encryption_required": @((props & CBCharacteristicPropertyIndicateEncryptionRequired) != 0),
    };

    // See BmBluetoothCharacteristic
    return @{
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID uuidStr],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID uuidStr] : [NSNull null],
        @"characteristic_uuid":    [characteristic.UUID uuidStr],
        @"descriptors":            descriptors,
        @"properties":             propsMap,
    };
}

//////////////////////////////////////////
// ██    ██ ████████  ██  ██       ███████ 
// ██    ██    ██     ██  ██       ██      
// ██    ██    ██     ██  ██       ███████ 
// ██    ██    ██     ██  ██            ██ 
//  ██████     ██     ██  ███████  ███████ 

- (bool)isAdapterOn
{
    return self.centralManager.state == CBManagerStatePoweredOn;
}

- (NSInteger)scanCountIncrement:(NSString *)remoteId {
    if (!self.scanCounts[remoteId]) {self.scanCounts[remoteId] = @(0);}
    NSInteger count = [self.scanCounts[remoteId] integerValue];
    self.scanCounts[remoteId] = @(count + 1);
    return count;
}

- (BOOL)filterKeywords:(NSArray<NSString *> *)keywords
                target:(NSString *)target
{
    if (keywords.count == 0) {
        return YES;
    }
    if (target == nil) {
        return NO;
    }
    for (NSString *k in keywords) {
        if ([target rangeOfString:k].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)filterNames:(NSArray<NSString *> *)names
                target:(NSString *)target
{
    if (names.count == 0) {
        return YES;
    }
    if (target == nil) {
        return NO;
    }
    for (NSString *n in names) {
        if ([target isEqualToString:n]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)filterRemoteIds:(NSArray<NSString *> *)remoteIds
                target:(NSString *)target
{
    if (remoteIds.count == 0) {
        return YES;
    }
    if (target == nil) {
        return NO;
    }
    for (NSString *r in remoteIds) {
        if ([[target lowercaseString] isEqualToString:[r lowercaseString]]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)filterServiceData:(NSArray<NSDictionary*>*)filters
                       sd:(NSDictionary *)sd
{
    if (filters.count == 0) {
        return YES;
    }
    if (sd == nil || sd.count == 0) {
        return NO;
    }
    for (NSDictionary *f in filters) {
        NSString *service                   = f[@"service"];
        NSData *data = [self convertHexToData:f[@"data"]];
        NSData *mask = [self convertHexToData:f[@"mask"]];

        // mask
        if (mask.length == 0 && data.length > 0) {
            uint8_t *bytes = malloc(data.length);
            memset(bytes, 1, data.length); 
            mask = [NSData dataWithBytesNoCopy:bytes length:data.length freeWhenDone:YES];
        }

        // found a match?
        for (CBUUID *uuid in sd) {
            NSString* a = [uuid.UUIDString lowercaseString];
            NSString* b = [service lowercaseString];
            if([a isEqualToString:b] && [self findData:data inData:sd[uuid] usingMask:mask]) {
                return YES;
            }
        }
    }
    return NO;
}

- (BOOL)filterMsd:(NSArray<NSDictionary*>*)filters
              msd:(NSData *)msd
{
    if (filters.count == 0) {
        return YES;
    }
    if (msd == nil || msd.length == 0) {
        return NO;
    }
    for (NSDictionary *f in filters) {
        NSNumber *manufacturerId            = f[@"manufacturer_id"];
        NSData *data = [self convertHexToData:f[@"data"]];
        NSData *mask = [self convertHexToData:f[@"mask"]];

        // first 2 bytes are manufacturer id
        unsigned short mId = 0;
        [msd getBytes:&mId length:2];

        // mask
        if (mask.length == 0 && data.length > 0) {
            uint8_t *bytes = malloc(data.length);
            memset(bytes, 1, data.length); 
            mask = [NSData dataWithBytesNoCopy:bytes length:data.length freeWhenDone:YES];
        }

        // trim off first 2 bytes
        NSData* trim = [msd subdataWithRange:NSMakeRange(2, msd.length - 2)];

        // manufacturer id & data
        if(mId == [manufacturerId integerValue] && [self findData:data inData:trim usingMask:mask]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)findData:(NSData *)find inData:(NSData *)data usingMask:(NSData *)mask {
    // Ensure find & mask are same length
    if ([find length] != [mask length]) {
        return NO;
    }
    
    const uint8_t *bFind = [find bytes];
    const uint8_t *bData = [data bytes];
    const uint8_t *bMask = [mask bytes];
    
    for (NSUInteger i = 0; i < [find length]; i++) {
        // Perform bitwise AND with mask and then compare
        if ((bFind[i] & bMask[i]) != (bData[i] & bMask[i])) {
            return NO;
        }
    }
    
    return YES;
}

- (NSString *)convertDataToHex:(NSData *)data 
{
    if (data == nil) {
        return @"";
    }

    const unsigned char *bytes = (const unsigned char *)[data bytes];
    NSMutableString *hexString = [NSMutableString new];

    for (NSInteger i = 0; i < data.length; i++) {
        [hexString appendFormat:@"%02x", bytes[i]];
    }

    return [hexString copy];
}

- (NSData *)convertHexToData:(NSString *)hexString
{
    if (hexString.length % 2 != 0) {
        return nil;
    }

    NSMutableData *data = [NSMutableData new];

    for (NSInteger i = 0; i < hexString.length; i += 2) {
        unsigned int byte = 0;
        NSRange range = NSMakeRange(i, 2);
        [[NSScanner scannerWithString:[hexString substringWithRange:range]] scanHexInt:&byte];
        [data appendBytes:&byte length:1];
    }

    return [data copy];
}

- (NSString *)cbManagerStateString:(CBManagerState)adapterState
{
    switch (adapterState)
    {
        case CBManagerStateUnknown:      return @"CBManagerStateUnknown";
        case CBManagerStateUnsupported:  return @"CBManagerStateUnsupported";
        case CBManagerStateUnauthorized: return @"CBManagerStateUnauthorized";
        case CBManagerStateResetting:    return @"CBManagerStateResetting";
        case CBManagerStatePoweredOn:    return @"CBManagerStatePoweredOn";
        case CBManagerStatePoweredOff:   return @"CBManagerStatePoweredOff";
        default:                         return @"unhandled";
    }
    return @"";
}

- (void)log:(LogLevel)level
     format:(NSString *)format, ...
{
    if (level <= _logLevel)
    {
        va_list args;
        va_start(args, format);
        NSString* msg = [[NSString alloc] initWithFormat:format arguments:args];
        NSLog(@"%@", msg);
        va_end(args);
    }
}

- (int)getMaxPayload:(CBPeripheral *)peripheral forType:(CBCharacteristicWriteType)writeType allowLongWrite:(bool)allowLongWrite
{
    // if allowLongWrite is disabled, we can only write up to MTU-3
    if (allowLongWrite == false) {
        writeType = CBCharacteristicWriteWithoutResponse;
    }

    // For withoutResponse, or allowLongWrite == false
    //   iOS returns MTU-3. In theory, MTU can be as high as 65535 (16-bit).
    //   I've seen iOS return 524 for this value. But typically it is lower.
    //   The MTU negotiated by the OS depends on iOS version.
    //
    // For withResponse, 
    //   iOS typically returns a constant value of 512, regardless of MTU. 
    //   This is because iOS will autosplit large writes
    int maxForType = (int) [peripheral maximumWriteValueLengthForType:writeType];

    // In order to operate the same on both iOS & Android, we enforce a 
    // maximum of 512, which is the same as android. This is also the
    // maxAttrLen of a characteristic in the BLE specification.
    return MIN(maxForType, 512);
}

- (int)getMtu:(CBPeripheral *)peripheral
{
    int maxPayload = [self getMaxPayload:peripheral forType:CBCharacteristicWriteWithoutResponse allowLongWrite:false];
    return maxPayload + 3; // ATT overhead
}

- (ServicePair *)getServicePair:(CBPeripheral *)peripheral
                 characteristic:(CBCharacteristic *)characteristic
{
    ServicePair* result = [[ServicePair alloc] init];

    CBService *service = characteristic.service;

    // is this a primary service?
    if ([service isPrimary]) {
        result.primary = service;
        result.secondary = NULL;
        return result;
    } 

    // Otherwise, iterate all services until we find the primary service
    for (CBService *primary in [peripheral services])
    {
        for (CBService *secondary in [primary includedServices])
        {
            if ([[secondary.UUID UUIDString] isEqualToString:[service.UUID UUIDString]])
            {
                result.primary = primary;
                result.secondary = secondary;
                return result;
            }
        }
    }

    return result;
}

- (NSData *)descriptorToData:(CBDescriptor *)descriptor
{
    NSData* data = nil;
    if (descriptor.value)
    {
        if ([descriptor.value isKindOfClass:[NSString class]])
        {
            // NSString
            data = [descriptor.value dataUsingEncoding:NSUTF8StringEncoding];
        }
        else if ([descriptor.value isKindOfClass:[NSNumber class]])
        {
            // NSNumber
            int value = [descriptor.value intValue];
            data = [NSData dataWithBytes:&value length:sizeof(value)];
        } 
        else if ([descriptor.value isKindOfClass:[NSData class]])
        {
            // NSData
            data = descriptor.value;
        }
    }
    return data;
}
@end
