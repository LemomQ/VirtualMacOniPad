#import <UIKit/UIKit.h>

// Keep localization at the thin UIKit layer. Framework and compatibility
// code must never depend on the user's language or mutate host behavior.
#define VZL(key) NSLocalizedString((key), nil)

NS_INLINE BOOL VZHostIsPhoneDevice(void)
{
    return UIDevice.currentDevice.userInterfaceIdiom ==
        UIUserInterfaceIdiomPhone;
}

NS_INLINE BOOL VZHostUsesPhoneIdiom(void)
{
    BOOL phone = VZHostIsPhoneDevice();
    // Development override for exercising the opposite device idiom without
    // making production behavior depend on window width:
    // defaults write com.mac.virtual VZSimulateAlternateUI -bool YES
    if ([NSUserDefaults.standardUserDefaults
            boolForKey:@"VZSimulateAlternateUI"])
        phone = !phone;
    return phone;
}

NS_INLINE NSString *VZDeviceString(NSString *iPadString,
                                   NSString *iPhoneString)
{
    return VZHostUsesPhoneIdiom() ? iPhoneString : iPadString;
}
