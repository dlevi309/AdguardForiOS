/**
    This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
    Copyright © Adguard Software Limited. All rights reserved.
 
    Adguard for iOS is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
 
    Adguard for iOS is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
 
    You should have received a copy of the GNU General Public License
    along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "PacketTunnelProvider.h"

#import <UIKit/UIDevice.h>

#import "ACommons/ACLang.h"
#import "ACommons/ACNetwork.h"
#import "APTunnelConnectionsHandler.h"
#import "APSharedResources.h"
#import "APTunnelConnectionsHandler.h"

#import "ASDatabase.h"
#import "ACNIPUtils.h"
#import "APDnsServerAddress.h"
#import "ACNCidrRange.h"
#import "ACDnsUtils.h"

#import "Adguard-Swift.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <resolv.h>
#include <dns.h>
#include <net/if.h>

/////////////////////////////////////////////////////////////////////
#pragma mark - PacketTunnelProvider Constants

NSString *APTunnelProviderErrorDomain = @"APTunnelProviderErrorDomain";

#define V_REMOTE_ADDRESS                        @"127.1.1.1"

#define V_INTERFACE_IPV4_ADDRESS                @"172.16.209.2"
#define V_INTERFACE_IPV4_MASK                   @"255.255.255.252"
#define V_INTERFACE_IPV4_FULL_MASK              @"255.255.255.255"

#define V_INTERFACE_IPV6_ADDRESS                @"fd12:1:1:1::2"
#define V_INTERFACE_IPV6_MASK                   @(64)
#define V_INTERFACE_IPV6_FULL_MASK              @(128)

#define V_DNS_IPV6_ADDRESS                      @"2001:ad00:ad00::ad00"
#define V_DNS_IPV6_FALLBACK                     @"2001:4860:4860::8888"

#define V_DNS_IPV4_ADDRESS                      @"198.18.0.1"
#define V_DNS_IPV4_FALLBACK                     @"8.8.8.8"

#define V_DNSPROXY_LOCAL_ADDDRESS               @"127.0.0.1"
#define V_DNSPROXY_LOCAL_ADDDRESS_IPV6          @"::1"

#define DNS_PROXY_MAX_QUEUES 10

/////////////////////////////////////////////////////////////////////
#pragma mark - PacketTunnelProvider

@implementation NEIPv6Route(cidr)

+ (NEIPv6Route*) ipv6RouteWithCidr:(NSString*)cidr {
    
    NSArray* components = [cidr componentsSeparatedByString:@"/"];
    if(components.count != 2)
        return nil;
    
    NSString* dest = components[0];
    
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSNumber *mask = [formatter numberFromString:components[1]];
    
    return [[NEIPv6Route alloc] initWithDestinationAddress:dest networkPrefixLength:mask];
}



@end

@implementation NEIPv4Route(cidr)
+ (NEIPv4Route*) ipv4RouteWithCidr:(NSString*)cidr {
    
    NSArray<NSString*>* components = [cidr componentsSeparatedByString:@"/"];
    if(components.count != 2)
        return nil;
    
    NSString* dest = components[0];
    
    int maskLength = [components[1] intValue];
    in_addr_t maskLong = 0xffffffff >> (32 - maskLength) << (32 - maskLength);
    maskLong = CFSwapInt32(maskLong);
    const char *buf = addr2ascii(AF_INET, &maskLong, sizeof(maskLong), NULL);
    NSString *mask = [NSString stringWithCString:buf
                                        encoding:NSUTF8StringEncoding];
    
    return [[NEIPv4Route alloc] initWithDestinationAddress:dest subnetMask:mask];
}
@end

@implementation PacketTunnelProvider{
    
    DnsServerInfo *_currentServer;
    APVpnManagerTunnelMode _tunnelMode;
    BOOL _restartByRechability;
    
    Reachability *_reachabilityHandler;
    APTunnelConnectionsHandler *_connectionHandler;
    
    NetworkStatus _lastReachabilityStatus;
    
    APSharedResources* _resources;
    
    DnsProxyService* _dnsProxy;
    
    DnsProvidersService* _dnsProvidersService;
}

+ (void)initialize{

    if (self == [PacketTunnelProvider class]) {

        // Init Logger
        [[ACLLogger singleton] initLogger:[AESharedResources sharedAppLogsURL]];

#if DEBUG
        [[ACLLogger singleton] setLogLevel:ACLLVerboseLevel];
#endif
    }
}

- (id)init {
    
    self = [super init];
    if (self) {
        
        _resources = [APSharedResources new];
        
        _reachabilityHandler = [Reachability reachabilityForInternetConnection];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachNotify:) name:kReachabilityChangedNotification object:nil];
        
        id<DnsLogRecordsWriterProtocol> logWriter = [[DnsLogRecordsWriter alloc] initWithResources:_resources];
        _dnsProxy = [[DnsProxyService alloc] initWithLogWriter:logWriter maxQueues: DNS_PROXY_MAX_QUEUES];
        _dnsProvidersService = [DnsProvidersService new];
        _connectionHandler = [[APTunnelConnectionsHandler alloc] initWithProvider:self dnsProxy:_dnsProxy];
    }
    return self;
}

/////////////////////////////////////////////////////////////////////
#pragma mark Controll connection methods

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler
{
    
    DDLogInfo(@"(PacketTunnelProvider) Start Tunnel Event");
    
    [_reachabilityHandler startNotifier];
    _lastReachabilityStatus = [_reachabilityHandler currentReachabilityStatus];
    
    ASSIGN_WEAK(self);
    
    [self updateTunnelSettingsWithCompletionHandler:^(NSError * _Nullable error) {
        
        ASSIGN_STRONG(self);
        
        if (USE_STRONG(self)->_connectionHandler) {
            [USE_STRONG(self)->_connectionHandler startHandlingPackets];
            DDLogInfo(@"(PacketTunnelProvider) connectionHandler started handling packets.");
        }
        
        DDLogInfo(@"(PacketTunnelProvider) Call start completionHandler.");
        completionHandler(error);
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler
{
	// Add code here to start the process of stopping the tunnel.
    DDLogInfo(@"(PacketTunnelProvider) Stop Tunnel Event");
    
    NSString *reasonString;
    
    switch (reason) {
        case NEProviderStopReasonNone:
            reasonString = @"NEProviderStopReasonNone No specific reason. ";
            break;
        case NEProviderStopReasonUserInitiated:
            reasonString = @"NEProviderStopReasonUserInitiated The user stopped the provider. ";
            break;
        case NEProviderStopReasonProviderFailed:
            reasonString = @"NEProviderStopReasonProviderFailed The provider failed. ";
            break;
        case NEProviderStopReasonNoNetworkAvailable:
            reasonString = @"NEProviderStopReasonNoNetworkAvailable There is no network connectivity. ";
            break;
        case NEProviderStopReasonUnrecoverableNetworkChange:
            reasonString = @"NEProviderStopReasonUnrecoverableNetworkChange The device attached to a new network. ";
            break;
        case NEProviderStopReasonProviderDisabled:
            reasonString = @"NEProviderStopReasonProviderDisabled The provider was disabled. ";
            break;
        case NEProviderStopReasonAuthenticationCanceled:
            reasonString = @"NEProviderStopReasonAuthenticationCanceled The authentication process was cancelled. ";
            break;
        case NEProviderStopReasonConfigurationFailed:
            reasonString = @"NEProviderStopReasonConfigurationFailed The provider could not be configured. ";
            break;
        case NEProviderStopReasonIdleTimeout:
            reasonString = @"NEProviderStopReasonIdleTimeout The provider was idle for too long. ";
            break;
        case NEProviderStopReasonConfigurationDisabled:
            reasonString = @"NEProviderStopReasonConfigurationDisabled The associated configuration was disabled. ";
            break;
        case NEProviderStopReasonConfigurationRemoved:
            reasonString = @"NEProviderStopReasonConfigurationRemoved The associated configuration was deleted. ";
            break;
        case NEProviderStopReasonSuperceded:
            reasonString = @"NEProviderStopReasonSuperceded A high-priority configuration was started. ";
            break;
        case NEProviderStopReasonUserLogout:
            reasonString = @"NEProviderStopReasonUserLogout The user logged out. ";
            break;
        case NEProviderStopReasonUserSwitch:
            reasonString = @"NEProviderStopReasonUserSwitch The active user changed. ";
            break;
        case NEProviderStopReasonConnectionFailed:
            reasonString = @"NEProviderStopReasonConnectionFailed Failed to establish connection. ";
            break;
            
        default:
            reasonString = @"Unknown reason. ";
            
    }
    DDLogInfo(@"(PacketTunnelProvider) Stop Tunnel Reason String:\n%@", reasonString);
    
    [_reachabilityHandler stopNotifier];
    
    [self logNetworkInterfaces];
    [_dnsProxy stopWithCallback:^{
        completionHandler();
    }];
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler
{
	// Add code here to get ready to sleep.
    DDLogInfo(@"(PacketTunnelProvider) Sleep Event");
    
    [self logNetworkInterfaces];
	completionHandler();
}

- (void)wake
{
	// Add code here to wake up.
    DDLogInfo(@"(PacketTunnelProvider) Wake Event");
    [self logNetworkInterfaces];
}

/////////////////////////////////////////////////////////////////////
#pragma mark Properties and public methods

- (DnsServerInfo *)currentDnsServer {
    
    return _currentServer;
}

- (APVpnManagerTunnelMode)tunnelMode {
    return _tunnelMode;
}

/////////////////////////////////////////////////////////////////////
#pragma mark Helper methods (private)

- (void)getDNSServersIpv4: (NSArray <APDnsServerAddress *> **)  ipv4DNSServers ipv6: (NSArray <APDnsServerAddress *> **) ipv6DNSServers {
  
    NSMutableArray<APDnsServerAddress*> *ipv4s = [NSMutableArray array];
    NSMutableArray<APDnsServerAddress*> *ipv6s = [NSMutableArray array];
    
    @autoreleasepool {
        
        [ACNIPUtils enumerateSystemDnsWithProcessingBlock:^(NSString *ip, NSString *port, BOOL ipv4, BOOL *stop) {
            if(ipv4)
               [ipv4s addObject:[[APDnsServerAddress alloc] initWithIp:ip port:port]];
            else
                [ipv6s addObject:[[APDnsServerAddress alloc] initWithIp:ip port:port]];
        }];
    }
    
    *ipv4DNSServers = [ipv4s copy];
    *ipv6DNSServers = [ipv6s copy];
    
    return;
}

- (void) updateTunnelSettingsWithCompletionHandler:(nonnull void (^)( NSError * __nullable error))completionHandler {
    
    // we need to reset network settings to remove our dns servers and read system default dns servers
    ASSIGN_WEAK(self);
    [self setTunnelNetworkSettings:nil completionHandler:^(NSError * _Nullable error) {
        
        ASSIGN_STRONG(self);
        
        [USE_STRONG(self) readProtocolConfiguration];
        
        [USE_STRONG(self)->_dnsProxy stopWithCallback:^{
            [USE_STRONG(self) startDnsProxy];
            [USE_STRONG(self) updateTunnelSettingsInternalWithCompletionHandler:completionHandler];
        }];
    }];
}

- (void) updateTunnelSettingsInternalWithCompletionHandler:(nonnull void (^)( NSError * __nullable error))completionHandler {
    DDLogInfo(@"(PacketTunnelProvider) Update Tunnel Settings");
    
    //create empty tunnel settings
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:V_REMOTE_ADDRESS];
    
    DDLogInfo(@"(PacketTunnelProvider) Empty tunnel settings created.");
    
    // Check configuration
    if(!_currentServer.upstreams.firstObject.length) {
        DDLogError(@"(PacketTunnelProvider) Can't obtain DNS addresses from protocol configuration.");
    }
    else {
        BOOL full = NO;
        BOOL withoutIcon = NO;
        
        NSString* modeName = @"";
        if (_tunnelMode == APVpnManagerTunnelModeSplit){
            modeName = @"SPLIT";
        }
        else if(_tunnelMode == APVpnManagerTunnelModeFull) {
            modeName = @"FULL";
            full = YES;
        }
        else if (_tunnelMode == APVpnManagerTunnelModeFullWithoutVPNIcon) {
            modeName = @"FULL without VPN icon";
            full = YES;
            withoutIcon = YES;
        }
        
        [self logNetworkInterfaces];
        DDLogInfo(@"PacketTunnelProvider) Start Tunnel mode: %@", modeName);
        
        settings = [self createTunnelSettings:full wihoutVPNIcon:withoutIcon];
        DDLogInfo(@"(PacketTunnelProvider) Tunnel settings filled.");
    }
    
    
    // SETs network settings
    ASSIGN_WEAK(self);
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *_Nullable error) {
        
        ASSIGN_STRONG(self);
        
        if(error)
            DDLogInfo(@"(PacketTunnelProvider) setTunnelNetworkSettings error : %@", error.localizedDescription);
        
        DDLogInfo(@"(PacketTunnelProvider) update Tunnel Settings ");
        completionHandler(error);
        
        [USE_STRONG(self) logNetworkInterfaces];
    }];
}

- (void) readProtocolConfiguration {
    
    // Getting DNS
    NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)self.protocolConfiguration;
    
    _currentServer = nil;
    NSData *currentServerData = protocol.providerConfiguration[APVpnManagerParameterRemoteDnsServer];
    if (currentServerData) {
        _currentServer = [NSKeyedUnarchiver unarchiveObjectWithData:currentServerData];
    }
    
    //protection for bad or old configuration
    if (_currentServer == nil) {
        _currentServer = [_dnsProvidersService defaultServer];
    }
    
    _tunnelMode = [protocol.providerConfiguration[APVpnManagerParameterTunnelMode] unsignedIntegerValue];
    
    NSNumber* restartValue = protocol.providerConfiguration[APVpnManagerRestartByReachability];
    _restartByRechability = restartValue ? [restartValue boolValue] : NO;
    
    DDLogInfo(@"(PacketTunnelProvider) Start Tunnel with configuration: %@", _currentServer.name);
}



- (void)reachNotify:(NSNotification *)note {
    
    DDLogInfo(@"(PacketTunnelProvider) reachability Notify. Status: %ld last status: %ld", (long)[_reachabilityHandler currentReachabilityStatus], _lastReachabilityStatus);
    
    // sometimes we recieve reach notify right after the tunnel is started(kSCNetworkReachabilityFlagsIsDirect flag changed). In this case the restart of the tunnel enters an infinite loop.
    if(_lastReachabilityStatus == [_reachabilityHandler currentReachabilityStatus]) {
        DDLogInfo(@"(PacketTunnelProvider) network status not changed. Skip reachability notify");
        return;
    }
    
    _lastReachabilityStatus = [_reachabilityHandler currentReachabilityStatus];
    
    // In some cases after a change from wifi to a mobile network, the system en(wi-fi) interfaces remain active.
    // At the same time, we normally receive requests in our tunnel, we correctly process them and receive replies from a remote server, but these answers do not reach the requesting application.
    // To avoid this situation, we close the tunnel for any reachability event.
    
    [_reachabilityHandler stopNotifier];
    
    // https://forums.developer.apple.com/thread/73432
    // reasseting shows "reconnecting" message in ios vpn settings
    // Also, it stops processing traffic through the tunnel.
    // Perhaps it will fix the internet connection failure https://github.com/AdguardTeam/AdguardForiOS/issues/772
    self.reasserting = YES;
    
    if(_restartByRechability) {
        
        DDLogInfo(@"(PacketTunnelProvider) stop tunnel");
        [_dnsProxy stopWithCallback:^{
            [self cancelTunnelWithError: nil];
        }];
    }
    else {
        
        DDLogInfo(@"(PacketTunnelProvider) update settings");
        [self updateSettings];
    }
}

- (void) updateSettings {
    
    ASSIGN_WEAK(self);
    
    void (^updateTunnelSettingsBlock)() = ^void() {
        
        DDLogInfo(@"(PacketTunnelProvider) updateSettings - update tunnel settings");
        
        ASSIGN_STRONG(self);
        [USE_STRONG(self) updateTunnelSettingsWithCompletionHandler:^(NSError * _Nullable error) {
            self.reasserting = NO;
            [_reachabilityHandler startNotifier];
        }];
    };
    
    [_dnsProxy stopWithCallback:^{
        [self startDnsProxy];
        updateTunnelSettingsBlock();
    }];
}

/**
 returns array of ipv4 exclude ranges for full tunnel modes
 
 withoutVPNIcon - it is a hack. If we add range 0.0.0.0 with mask 31 or lower to exclude routes, then vpn icon appears.
 It is important to understand that it's not just about the icon itself.
 The appearance and disappearance of the icon causes different strangeness in the behavior of the system.
 In mode "with the icon" does not work facetime(https://github.com/AdguardTeam/AdguardForiOS/issues/501).
 Perhaps some other apple services use the address 0.0.0.0 and does not work.
 In the "no icon" mode, you can not disable wi-fi(https://github.com/AdguardTeam/AdguardForiOS/issues/674).
 This behavior leads to crashes in ios 11.3 beta.
 
 NOTE. To show VPN icon it's enough to add either 0.0.0.0/(0-31) to ipv4 excludes or ::/(0-127) to ipv6 exclude routes.
 */
- (NSArray<NEIPv4Route *> *) ipv4ExcludedRoutesWithoutVPNIcon:(BOOL) withoutVPNIcon {
    
    NSMutableArray *ipv4excludeRoutes = [NSMutableArray new];
    
    ACNCidrRange *defaultRoute = [[ACNCidrRange alloc]initWithCidrString:@"0.0.0.0/0"];
    
    NSArray<ACNCidrRange*> * dnsRanges = @[[[ACNCidrRange alloc]initWithCidrString:V_DNS_IPV4_ADDRESS]];
    
    if(!withoutVPNIcon) {
        // see comment in method header
        dnsRanges = [dnsRanges arrayByAddingObject:[[ACNCidrRange alloc]initWithCidrString:@"0.0.0.0/31"]];
    }
    
    NSArray<ACNCidrRange*> *excludedRanges = [ACNCidrRange excludeFrom:@[defaultRoute] excludedRanges:dnsRanges];
    
    for (ACNCidrRange* range in excludedRanges) {
        NSString* cidr = [range toString];
        [ipv4excludeRoutes addObject:[NEIPv4Route ipv4RouteWithCidr:cidr]];
    }
    
    return ipv4excludeRoutes;
}

/**
 returns array of ipv6 ыexclude ranges for full tunnel modes
 
 NOTE. detailed description in the ipv4ExcludedRoutesWithoutVPNIcon header
 */
- (NSArray<NEIPv6Route *> *) ipv6ExcludedRoutesWithoutVPNIcon:(BOOL) withoutVPNIcon {
    
    NSMutableArray *ipv6ExcludedRoutes = [NSMutableArray new];
    
    ACNCidrRange *defaultRoute = [[ACNCidrRange alloc]initWithCidrString:@"::/0"];
    NSArray<ACNCidrRange*> * dnsRanges = @[[[ACNCidrRange alloc]initWithCidrString:V_DNS_IPV6_ADDRESS]];
    
    if(!withoutVPNIcon) {
        dnsRanges = [dnsRanges arrayByAddingObject:[[ACNCidrRange alloc]initWithCidrString:@"::/127"]];
    }
    
    NSArray<ACNCidrRange*> *excludedRanges = [ACNCidrRange excludeFrom:@[defaultRoute] excludedRanges:dnsRanges];
    
    for (ACNCidrRange* range in excludedRanges) {
        NSString* cidr = [range toString];
        [ipv6ExcludedRoutes addObject:[NEIPv6Route ipv6RouteWithCidr:cidr]];
    }
    
    return ipv6ExcludedRoutes;
}

- (NEPacketTunnelNetworkSettings *)createTunnelSettings: (BOOL)fullTunnel wihoutVPNIcon:(BOOL)withoutVPNIcon {

    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:V_REMOTE_ADDRESS];
    
    // DNS
    
    BOOL ipv4Available = [ACNIPUtils isIpv4Available];
    BOOL ipv6Available = [ACNIPUtils isIpv6Available];
    
    DDLogInfo(@"(PacketTunnelProvider) - createTunnelSettings. ipv4Available: %@  ipv6Available: %@", ipv4Available ? @"YES" : @"NO", ipv6Available ? @"YES" : @"NO");
    
    NSString* localDnsAddress = ipv4Available ? V_DNS_IPV4_ADDRESS : V_DNS_IPV6_ADDRESS;
    
    NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers: @[localDnsAddress]];
    
    dns.matchDomains = @[ @"" ];
    
    settings.DNSSettings = dns;
    
    // exclude routes
    
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc]
                            initWithAddresses:@[V_INTERFACE_IPV4_ADDRESS]
                            subnetMasks:@[V_INTERFACE_IPV4_MASK]];
    
    
    NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc]
                            initWithAddresses:@[V_INTERFACE_IPV6_ADDRESS]
                            networkPrefixLengths:@[V_INTERFACE_IPV6_MASK]];
    
    
    // include routes
    
    if(fullTunnel) {
        ipv4.includedRoutes = @[[NEIPv4Route defaultRoute]];
        ipv6.includedRoutes = @[[NEIPv6Route defaultRoute]];
        
        // To reduce the negative effects of "vpn icon", we don't exclude the zero route only for the IPv6 if it possible
        BOOL ipv4WithoutIcon = withoutVPNIcon || ipv6Available;
        
        ipv4.excludedRoutes = [self ipv4ExcludedRoutesWithoutVPNIcon:ipv4WithoutIcon];
        ipv6.excludedRoutes = [self ipv6ExcludedRoutesWithoutVPNIcon:withoutVPNIcon];
    }
    else {
        if (ipv4Available) {
            NEIPv4Route* dnsProxyIpv4Route = [[NEIPv4Route alloc]
                                              initWithDestinationAddress:V_DNS_IPV4_ADDRESS subnetMask:V_INTERFACE_IPV4_FULL_MASK];
            ipv4.includedRoutes = @[dnsProxyIpv4Route];
        }
        else {
            NEIPv6Route* dnsProxyIpv6Route = [[NEIPv6Route alloc]
                                              initWithDestinationAddress: V_DNS_IPV6_ADDRESS networkPrefixLength:V_INTERFACE_IPV6_FULL_MASK];
            
            ipv6.includedRoutes = @[dnsProxyIpv6Route];
        }
        ipv4.excludedRoutes = @[[NEIPv4Route defaultRoute]];
        ipv6.excludedRoutes = @[[NEIPv6Route defaultRoute]];
    }
    
    if(ipv4Available) {
        settings.IPv4Settings = ipv4;
    }
    
    if(ipv6Available) {
        settings.IPv6Settings = ipv6;
    }
    
    return settings;
}

- (void)logNetworkInterfaces {
    
    NSMutableString* log = [NSMutableString new];
    
    [ACNIPUtils enumerateNetworkInterfacesWithProcessingBlock:^(struct ifaddrs *addr, BOOL *stop) {
        
        NSString* address;
        if(addr->ifa_addr->sa_family == AF_INET){
            address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)addr->ifa_addr)->sin_addr)];
            
            NSString* interfaceString = [NSString stringWithFormat:@"%@/ipv4:%@", [NSString stringWithUTF8String:addr->ifa_name], address];
            [log appendFormat:@"%@\n", interfaceString];
        }
        else if(addr->ifa_addr->sa_family == AF_INET6){
            char ip[INET6_ADDRSTRLEN];
            const char *str = inet_ntop(AF_INET6, &(((struct sockaddr_in6 *)addr->ifa_addr)->sin6_addr), ip, INET6_ADDRSTRLEN);
            
            address = [NSString stringWithUTF8String:str];
            
            NSString* interfaceString = [NSString stringWithFormat:@"%@/ipv6:%@", [NSString stringWithUTF8String:addr->ifa_name], address];
            [log appendFormat:@"%@\n", interfaceString];
        }
    }];
    
    DDLogInfo(@"(PacketTunnelProvider) Available network interfaces:\n%@", log);
}

- (BOOL) startDnsProxy {
    
    DDLogInfo(@"(PacketTunelProvider) - startDnsProxy ");
    NSArray *upstreams = _currentServer.upstreams;
    
    NSArray<APDnsServerAddress*> *deviceIpv4DnsServers;
    NSArray<APDnsServerAddress*> *deviceIpv6DnsServers;
    
    [self getDNSServersIpv4:&deviceIpv4DnsServers ipv6:&deviceIpv6DnsServers];
    
    NSArray<APDnsServerAddress*> *allDeviceDnsServers = [deviceIpv4DnsServers arrayByAddingObjectsFromArray:deviceIpv6DnsServers];
    
    NSMutableArray<NSString*> *allSystemDnsIps = [NSMutableArray new];
    
    for (APDnsServerAddress* dns in allDeviceDnsServers) {
        [allSystemDnsIps addObject:dns.ip];
    }
    
    if (allSystemDnsIps.count == 0) {
        DDLogError(@"(PacketTunnelProvider) - startDnsProxy error. There is no system dns servers");
        return NO;
    }

    // Check if DNS servers found are actually our addresses
    // If for some reason we detect our own fake address instead of the system DNS,
    // fallback to some default DNS addresses in order avoid recursion
    for (int i = 0; i < allSystemDnsIps.count; i++) {
        if ([allSystemDnsIps[i]  isEqual: V_DNS_IPV4_ADDRESS]) {
            allSystemDnsIps[i] = V_DNS_IPV4_FALLBACK;
        } else if ([allSystemDnsIps[i]  isEqual: V_DNS_IPV6_ADDRESS]) {
            allSystemDnsIps[i] = V_DNS_IPV6_FALLBACK;
        }
    }
    
    NSString* systemDns = [allSystemDnsIps componentsJoinedByString:@"\n"];
    
    DDLogInfo(@"(PacketTunnelProvider) start DNS Proxy with upstreams: %@ systemDns: %@", upstreams, systemDns);
    
    BOOL ipv4Available = [ACNIPUtils isIpv4Available];
    return [_dnsProxy startWithUpstreams:upstreams listenAddr: ipv4Available ? V_DNSPROXY_LOCAL_ADDDRESS : V_DNSPROXY_LOCAL_ADDDRESS_IPV6 bootstrapDns: systemDns  fallback: systemDns serverName: _currentServer.name];
}

@end
