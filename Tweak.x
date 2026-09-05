#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import "libsmc.h"

extern void IONotificationPortSetDispatchQueue(IONotificationPortRef notifyPort, dispatch_queue_t queue);

// ---- Config ----------------------------------------------------------

static CFStringRef const kQLimitAppID                    = CFSTR("me.qlimit");
static CFStringRef const kQLimitPrefsUser                = CFSTR("mobile");
static CFStringRef const kQLimitMaxLevelKey              = CFSTR("MaxChargingLevel");
static CFStringRef const kQLimitSailDepthKey             = CFSTR("SailDepth");
static CFStringRef const kQShouldInhibitAccessoryChargingKey = CFSTR("ShouldInhibitAccessoryCharging");
static CFStringRef const kQLimitPrefsChangedNotification = CFSTR("me.qlimit/prefschanged");

static const int kQLimitDefaultLevel     = 80;
static const int kQLimitDefaultSailDepth = 5;
static const BOOL kQLimitDefaultShouldInhibitAccessoryCharging = NO;



#define QLIMIT_DEBUG 1
#if QLIMIT_DEBUG
    #define QLog(fmt, ...) \
        do { \
            FILE *f = fopen("/var/mobile/Library/Logs/qlimit.log", "a"); \
            if (f) { \
                fprintf(f, "[QLimit] " fmt "\n", ##__VA_ARGS__); \
                fclose(f); \
            } \
        } while (0)
#else
    #define QLog(fmt, ...) do {} while (0)
#endif

// ---- State -------------------------------------------------------------

static int _qlimitMaxChargingLevel = kQLimitDefaultLevel;
static int _qlimitSailDepth = kQLimitDefaultSailDepth;
static int _qlimitShouldInhibitAccessoryCharging = kQLimitDefaultShouldInhibitAccessoryCharging;


static IONotificationPortRef gNotifyPort = NULL;
static io_object_t gPowerNotification = IO_OBJECT_NULL;

// ---- Helpers ------------------------------------------------------------

static id qlimit_getProperty(io_service_t service, CFStringRef key) {
    if (!service) return nil;
    CFTypeRef prop = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    return prop ? (__bridge_transfer id)prop : nil;
}

static BOOL qlimit_isAdapterConnected(io_service_t service) {
    /*NSDictionary *details = qlimit_getProperty(service, CFSTR("AdapterDetails"));
    if (details) {
        NSString *desc = details[@"Description"];
        return (desc && ![desc isEqualToString:@"orion"]);
    }*/
    
    // Fallback if AdapterDetails is nil (e.g., standard 5W chargers / older devices)
    NSNumber *chargeCapable = qlimit_getProperty(service, CFSTR("ExternalChargeCapable"));
    if (chargeCapable) {
        return [chargeCapable boolValue];
    }

    return NO;
}

static BOOL qlimit_isAccessoryConnected(io_service_t service) {
    NSNumber *detect = qlimit_getProperty(service, CFSTR("IOAccessoryDetect"));
    return detect ? [detect boolValue] : NO;
}

// ---- Preferences ---------------------------------------------------------

static int qlimit_intPrefValue(CFStringRef key, int defaultValue) {
    id value = (__bridge_transfer id)CFPreferencesCopyValue(key, kQLimitAppID, kQLimitPrefsUser, kCFPreferencesCurrentHost);
    return value ? [value intValue] : defaultValue;
}

static void qlimit_loadPreferences(void) {
    CFPreferencesSynchronize(kQLimitAppID, kQLimitPrefsUser, kCFPreferencesCurrentHost);

    _qlimitMaxChargingLevel = qlimit_intPrefValue(kQLimitMaxLevelKey, kQLimitDefaultLevel);
    _qlimitSailDepth = qlimit_intPrefValue(kQLimitSailDepthKey, kQLimitDefaultSailDepth);

    _qlimitShouldInhibitAccessoryCharging = qlimit_intPrefValue(kQShouldInhibitAccessoryChargingKey, kQLimitDefaultShouldInhibitAccessoryCharging);

    QLog("Loaded Preferences: MaxLevel=%d, SailDepth=%d, accinhb=%s", _qlimitMaxChargingLevel, _qlimitSailDepth, _qlimitShouldInhibitAccessoryCharging ? "YES" : "NO");
}

// ---- Service Resolver ------------------------------

static io_service_t qlimit_getPowerService(void) {
    static io_service_t serv = IO_OBJECT_NULL;
    if (serv == IO_OBJECT_NULL) {
        serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
        if (serv == IO_OBJECT_NULL) {
            serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
        }
    }
    return serv;
}

static io_service_t qlimit_getAccessoryService(void) {
    static io_service_t serv = IO_OBJECT_NULL;
    if (serv == IO_OBJECT_NULL) {
        serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AWCAccessoryManager"));
    }
    return serv;
}

// ---- Control Primitives --------------------------------------------------

static BOOL qlimit_isChargeInhibited(void) {
    uint8_t val = 0;
    int32_t sz = sizeof(val);
    if (smc_read_safe('CH0C', &val, &sz) != kIOReturnSuccess) return NO;
    return val != 0;
}
static void qlimit_setChargeInhibited(BOOL inhibited) {
    uint8_t val = inhibited ? 1 : 0;
    __attribute__((unused)) IOReturn status = smc_write_safe('CH0C', &val, 1);
    QLog("smc_write_safe status 0x%x, inhibited = %s", status, inhibited ? "YES" : "NO");
}

static BOOL qlimit_isAccessoryChargeInhibited(void) {
    uint8_t val = 0;
    int32_t sz = sizeof(val);
    if (smc_read_safe('AY1C', &val, &sz) != kIOReturnSuccess) return NO;
    return val != 0;
}
static void qlimit_setAccessoryChargeInhibited(BOOL inhibited) {
    uint8_t val = inhibited ? 1 : 0;
    __attribute__((unused)) IOReturn status = smc_write_safe('AY1C', &val, 1);
    QLog("smc_write_safe for accessory status 0x%x, inhibited = %s", status, inhibited ? "YES" : "NO");
}

// ---- Decision logic ---------------------------------------------------------

static void qlimit_evaluateChargingState(void) {
    io_service_t service = qlimit_getPowerService();
    if (!service) {
        QLog("Error evaluating charging state: No service available.");
        return;
    }

    BOOL isPluggedIn = qlimit_isAdapterConnected(service);

    NSNumber *capNum = qlimit_getProperty(service, CFSTR("CurrentCapacity"));
    if (capNum) {
        int capacity = [capNum intValue];

        BOOL isInhibited = qlimit_isChargeInhibited();

        QLog("Evaluating: PluggedIn=%s, Capacity=%d%%, Inhibited=%s, MaxThreshold=%d%%, ResumeThreshold=%d%%", isPluggedIn ? "YES" : "NO", capacity, isInhibited ? "YES" : "NO", _qlimitMaxChargingLevel, (_qlimitMaxChargingLevel - _qlimitSailDepth));
        
        if (isPluggedIn) {
            if ((capacity >= _qlimitMaxChargingLevel) && !isInhibited) {
                QLog("Max battery limit reached (%d >= %d). Halting charge.", capacity, _qlimitMaxChargingLevel);
                qlimit_setChargeInhibited(YES);
            } else if ((capacity <= (_qlimitMaxChargingLevel - _qlimitSailDepth)) && isInhibited) {
                QLog("Sailing threshold reached (%d <= %d). Resuming charge.", capacity, (_qlimitMaxChargingLevel - _qlimitSailDepth));
                qlimit_setChargeInhibited(NO);
            }
        } else { //not plugged in
            if (isInhibited) {
                QLog("Device is unplugged. Resetting charge inhibit.");
                qlimit_setChargeInhibited(NO);
            }
        }
    } else {
        QLog("Failed to read CurrentCapacity from IOKit service.");
    }
}

static uint8_t qlimit_numAccPorts() {
    uint8_t count = 0;
    kern_return_t kr = smc_read_n('AY-N', &count, 1)
    QLog("Port count thru SMC: %d, with result: 0x%x", count, kr);
    return count;
}

static void qlimit_evaluateAccessoryChargingState(void) {
    io_service_t service = qlimit_getAccessoryService();
    if (!service) {
        QLog("Error evaluating charging state: No accessory service available.");
        return;
    }

    BOOL isPresent = qlimit_isAccessoryConnected(service);

    if (isPresent) {

        BOOL isInhibited = qlimit_isAccessoryChargeInhibited();

        QLog("Evaluating: Present=%s, Inhibited=%s", isPresent ? "YES" : "NO", isInhibited ? "YES" : "NO");
        qlimit_numAccPorts();

        if (_qlimitShouldInhibitAccessoryCharging && !isInhibited) {
            qlimit_setAccessoryChargeInhibited(YES);
        } else if (!_qlimitShouldInhibitAccessoryCharging && isInhibited) {
            qlimit_setAccessoryChargeInhibited(NO);
        }
    } else {
        qlimit_numAccPorts();
    }
}

// ---- Callbacks ---------------------------------------------------------

static void qlimit_powerSourceChangedCallback(void *refcon, io_service_t service, uint32_t messageType, void *messageArgument) {
    QLog("IOKit Power Event Fired: messageType = 0x%x", messageType);
    qlimit_evaluateChargingState();
    qlimit_evaluateAccessoryChargingState();
}

static void qlimit_preferencesChangedCallback(CFNotificationCenterRef center,
                                               void *observer,
                                               CFStringRef name,
                                               const void *object,
                                               CFDictionaryRef userInfo) {
    QLog("Darwin notification received: Preferences changed.");
    qlimit_loadPreferences();
    qlimit_evaluateChargingState();
}

// ---- Setup Low-Level Hook ------------

static void qlimit_setupNotification(void) {
    gNotifyPort = IONotificationPortCreate(kIOMasterPortDefault);
    if (!gNotifyPort) {
        QLog("Failed to create IONotificationPort!");
        return;
    }

    IONotificationPortSetDispatchQueue(gNotifyPort, dispatch_get_main_queue());

    io_service_t serv = qlimit_getPowerService();
    QLog("Matching PowerSource handle: %u", serv);
    
    if (serv != IO_OBJECT_NULL) {
        __attribute__((unused)) kern_return_t kr = IOServiceAddInterestNotification(
            gNotifyPort, 
            serv, 
            "IOGeneralInterest", 
            (IOServiceInterestCallback)qlimit_powerSourceChangedCallback, 
            NULL, 
            &gPowerNotification
        );

        QLog("Notification status code: 0x%x, Handle: %u", kr, gPowerNotification);
    }
}

// ---- Entry point ---------------------------------------------------------

%ctor {
    smc_open();
    
    qlimit_loadPreferences();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     NULL,
                                     qlimit_preferencesChangedCallback,
                                     kQLimitPrefsChangedNotification,
                                     NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);

    qlimit_setupNotification();

    dispatch_async(dispatch_get_main_queue(), ^{
        qlimit_evaluateChargingState();
        qlimit_evaluateAccessoryChargingState();
    });
}
