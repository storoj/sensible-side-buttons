//
//  AppDelegate.m
//
// SensibleSideButtons, a utility that fixes the navigation buttons on third-party mice in macOS
// Copyright (C) 2018 Alexei Baboulevitch (ssb@archagon.net)
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//

#import "AppDelegate.h"
#import "TouchEvents.h"

static void SBFFakeSwipe(TLInfoSwipeDirection dir) {
    NSDictionary* swipeInfo1 = @{
        (id)kTLInfoKeyGestureSubtype: @(kTLInfoSubtypeSwipe),
        (id)kTLInfoKeyGesturePhase: @(1)
    };
    NSDictionary* swipeInfo2 = @{
        (id)kTLInfoKeyGestureSubtype: @(kTLInfoSubtypeSwipe),
        (id)kTLInfoKeySwipeDirection: @(dir),
        (id)kTLInfoKeyGesturePhase: @(4)
    };
    
    NSArray *touches = @[];
    
    CGEventRef event1 = tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)swipeInfo1, (__bridge CFArrayRef)touches);
    CGEventRef event2 = tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)swipeInfo2, (__bridge CFArrayRef)touches);
    
    CGEventPost(kCGHIDEventTap, event1);
    CGEventPost(kCGHIDEventTap, event2);
    
    CFRelease(event1);
    CFRelease(event2);
}

const CGMouseButton kCGMouseButtonBack = 3;
const CGMouseButton kCGMouseButtonForward = 4;

static CGEventRef SBFMouseCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    int64_t number = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    
    switch (number) {
        case kCGMouseButtonBack:
        case kCGMouseButtonForward: {
            BOOL down = (CGEventGetType(event) == kCGEventOtherMouseDown);
            BOOL mouseDown = [[NSUserDefaults standardUserDefaults] boolForKey:@"SBFMouseDown"];
            BOOL swapButtons = [[NSUserDefaults standardUserDefaults] boolForKey:@"SBFSwapButtons"];

            if (!(mouseDown ^ down)) {
                BOOL back = ((number == kCGMouseButtonBack) ^ swapButtons);
                SBFFakeSwipe(back ? kTLInfoSwipeLeft : kTLInfoSwipeRight);
            }
            return NULL;
        }
        default:
            return event;
    }
}

typedef NS_ENUM(NSInteger, MenuMode) {
    MenuModeAccessibility,
    MenuModeDonation,
    MenuModeNormal
};

@interface AboutView: NSView
@property (nonatomic, strong) NSTextView* text;
@property (nonatomic, assign) MenuMode menuMode;
- (void)sizeToFit;
@end

@interface AppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem* statusItem;
@property (nonatomic, assign) CFMachPortRef tap;
@property (nonatomic, assign) MenuMode menuMode;

@property (nonatomic, strong) NSMenuItem *enabledItem;
@property (nonatomic, strong) NSMenuItem *modeItem;
@property (nonatomic, strong) NSMenuItem *swapItem;
@property (nonatomic, strong) NSMenuItem *hideItem;
@property (nonatomic, strong) NSMenuItem *hideInfoItem;
@property (nonatomic, strong) NSMenuItem *aboutItem;
@property (nonatomic, strong) NSMenuItem *donateItem;
@property (nonatomic, strong) NSMenuItem *websiteItem;
@property (nonatomic, strong) NSMenuItem *accessibilityItem;

@property (nonatomic, strong) AboutView *aboutView;
@end


@implementation AppDelegate

-(void) dealloc {
    [self startTap:NO];
}

-(void) setMenuMode:(MenuMode)menuMode {
    _menuMode = menuMode;
    self.aboutView.menuMode = menuMode;
    [self refreshSettings];
}

// if the application is launched when it's already running, show the icon in the menu bar again
-(BOOL) applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (@available(macOS 10.12, *)) {
        [self.statusItem setVisible:YES];
    }
    return NO;
}

-(void) applicationDidFinishLaunching:(NSNotification *)aNotification {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
                                                              @"SBFWasEnabled": @YES,
                                                              @"SBFMouseDown": @YES,
                                                              @"SBFDonated": @NO,
                                                              @"SBFSwapButtons": @NO
                                                              }];
    
    // create status bar item
    {
        self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    }
    
    // create menu
    {
        NSMenu* menu = [NSMenu new];
        
        menu.autoenablesItems = NO;
        menu.delegate = self;
        
        _enabledItem = [[NSMenuItem alloc] initWithTitle:@"Enabled" action:@selector(enabledToggle:) keyEquivalent:@"e"];
        [menu addItem:_enabledItem];
        
        [menu addItem:[NSMenuItem separatorItem]];
        
        _modeItem = [[NSMenuItem alloc] initWithTitle:@"Trigger on Mouse Down" action:@selector(mouseDownToggle:) keyEquivalent:@""];
        _modeItem.state = NSControlStateValueOn;
        [menu addItem:_modeItem];
        
        _swapItem = [[NSMenuItem alloc] initWithTitle:@"Swap Buttons" action:@selector(swapToggle:) keyEquivalent:@""];
        _swapItem.state = NSControlStateValueOff;
        [menu addItem:_swapItem];
        
        [menu addItem:[NSMenuItem separatorItem]];
        
        _hideItem = [[NSMenuItem alloc] initWithTitle:@"Hide Menu Bar Icon" action:@selector(hideMenubarItem:) keyEquivalent:@""];
        [menu addItem:_hideItem];
        
        _hideInfoItem = [[NSMenuItem alloc] initWithTitle:@"Relaunch application to show again" action:NULL keyEquivalent:@""];
        [_hideInfoItem setEnabled:NO];
        [menu addItem:_hideInfoItem];
        
        [menu addItem:[NSMenuItem separatorItem]];
        
        _aboutView = [[AboutView alloc] initWithFrame:NSMakeRect(0, 0, 320, 0)];
        _aboutItem = [[NSMenuItem alloc] initWithTitle:@"Text" action:NULL keyEquivalent:@""];
        _aboutItem.view = _aboutView;
        [menu addItem:_aboutItem];
        
        [menu addItem:[NSMenuItem separatorItem]];
        
        NSString* appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey];
        _donateItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ Website", appName] action:@selector(donate:) keyEquivalent:@""];
        [menu addItem:_donateItem];
        
        _websiteItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ Website", appName] action:@selector(website:) keyEquivalent:@""];
        [menu addItem:_websiteItem];
        
        _accessibilityItem = [[NSMenuItem alloc] initWithTitle:@"Open Accessibility Whitelist" action:@selector(accessibility:) keyEquivalent:@""];
        [menu addItem:_accessibilityItem];
        
        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem* quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
        quit.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        [menu addItem:quit];
        
        self.statusItem.menu = menu;
    }
    
    [self startTap:[[NSUserDefaults standardUserDefaults] boolForKey:@"SBFWasEnabled"]];
    
    [self updateMenuMode];
    [self refreshSettings];
}

-(void) updateMenuMode {
    [self updateMenuMode:YES];
}

-(void) updateMenuMode:(BOOL)active {
    // TODO: this actually returns YES if SSB is deleted (not disabled) from Accessibility
    NSDictionary* options = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @(active ? YES : NO) };
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions((CFDictionaryRef)options);
    //BOOL accessibilityEnabled = YES; //is accessibility even required? seems to work fine without it
    
    if (accessibilityEnabled) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"SBFDonated"]) {
            self.menuMode = MenuModeNormal;
        }
        else {
            self.menuMode = MenuModeDonation;
        }
    }
    else {
        self.menuMode = MenuModeAccessibility;
    }
    
    // QQQ: for testing
    //self.menuMode = arc4random_uniform(3);
}

-(void) refreshSettings {
    self.enabledItem.state = self.tap != NULL && CGEventTapIsEnabled(self.tap);
    self.modeItem.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"SBFMouseDown"];
    self.swapItem.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"SBFSwapButtons"];
    
    {
        MenuMode mode = self.menuMode;
        
        self.enabledItem.enabled = (mode != MenuModeAccessibility);
        self.modeItem.enabled = (mode != MenuModeAccessibility);
        self.swapItem.enabled = (mode != MenuModeAccessibility);
        
        self.donateItem.hidden = (mode != MenuModeDonation);
        self.websiteItem.hidden = (mode == MenuModeDonation);
        self.accessibilityItem.hidden = (mode != MenuModeAccessibility);
    }
    
    [self.aboutView sizeToFit];
    
    // only show the menu item to hide the icon if the API is available
    if (@available(macOS 10.12, *)) {
        self.hideItem.hidden = NO;
        self.hideInfoItem.hidden = NO;
    }
    else {
        self.hideItem.hidden = YES;
        self.hideInfoItem.hidden = YES;
    }
    
    if (self.statusItem.button != nil) {
        if (self.tap != NULL && CGEventTapIsEnabled(self.tap)) {
            self.statusItem.button.image = [NSImage imageNamed:@"MenuIcon"];
        }
        else {
            self.statusItem.button.image = [NSImage imageNamed:@"MenuIconDisabled"];
        }
    }
}

-(void) startTap:(BOOL)start {
    if (start) {
        if (self.tap == NULL) {
            self.tap = CGEventTapCreate(kCGHIDEventTap,
                                        kCGHeadInsertEventTap,
                                        kCGEventTapOptionDefault,
                                        CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventOtherMouseDown),
                                        &SBFMouseCallback,
                                        NULL);
            
            if (self.tap != NULL) {
                CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(NULL, self.tap, 0);
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CFRelease(runLoopSource);
                
                CGEventTapEnable(self.tap, true);
            }
        }
    }
    else {
        if (self.tap != NULL) {
            CGEventTapEnable(self.tap, NO);
            CFRelease(self.tap);
            
            self.tap = NULL;
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setBool:self.tap != NULL && CGEventTapIsEnabled(self.tap) forKey:@"SBFWasEnabled"];
}

-(void) enabledToggle:(id)sender {
    [self startTap:self.tap == NULL];
    [self refreshSettings];
}

-(void) mouseDownToggle:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:![[NSUserDefaults standardUserDefaults] boolForKey:@"SBFMouseDown"] forKey:@"SBFMouseDown"];
    [self refreshSettings];
}

-(void) swapToggle:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:![[NSUserDefaults standardUserDefaults] boolForKey:@"SBFSwapButtons"] forKey:@"SBFSwapButtons"];
    [self refreshSettings];
}

-(void) donate:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: @"http://sensible-side-buttons.archagon.net#donations"]];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"SBFDonated"];
    
    [self updateMenuMode];
    [self refreshSettings];
}

-(void) website:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: @"http://sensible-side-buttons.archagon.net"]];
}

-(void) accessibility:(id)sender {
    [self updateMenuMode];
    [self refreshSettings];
}

-(void) hideMenubarItem:(id)sender {
    if (@available(macOS 10.12, *)) {
        [self.statusItem setVisible:NO];
    }
}

-(void) quit:(id)sender {
    [NSApp terminate:self];
}

- (void) menuWillOpen:(NSMenu*)menu {
    // TODO: theoretically, accessibility can be disabled while the menu is opened, but this is unlikely
    [self updateMenuMode:NO];
    [self refreshSettings];
}

@end

@implementation AboutView

-(CGFloat) margin {
    return 17;
}

-(void) setMenuMode:(MenuMode)menuMode {
    _menuMode = menuMode;
    
    NSFont* font = [NSFont menuFontOfSize:13];
    
    NSFontDescriptor* boldFontDesc = [NSFontDescriptor fontDescriptorWithFontAttributes:@{
                                                                                          NSFontFamilyAttribute: font.familyName,
                                                                                          NSFontFaceAttribute: @"Bold"
                                                                                          }];
    NSFont* boldFont = [NSFont fontWithDescriptor:boldFontDesc size:font.pointSize];
    if (!boldFont) { boldFont = font; }
    
    NSColor* regularColor = [NSColor secondaryLabelColor];
    NSColor* alertColor = [NSColor systemRedColor];
    
    NSDictionary* regularAttributes = @{
                                 NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: regularColor
                                 };
    NSDictionary* alertAttributes = @{
                                      NSFontAttributeName: font,
                                      NSForegroundColorAttributeName: alertColor
                                      };
    NSDictionary* smallReturnAttributes = @{
                                            NSFontAttributeName: [NSFont menuFontOfSize:3],
                                            };
    
    NSString* appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey];
    NSString* appDescription = [NSString stringWithFormat:@"%@ %@", appName, [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"]];
    NSString* copyright = @"Copyright © 2018 Alexei Baboulevitch.";
    
    switch (menuMode) {
        case MenuModeAccessibility: {
            NSString* text = [NSString stringWithFormat:@"Uh-oh! It looks like %@ is not whitelisted in the Accessibility panel of your Security & Privacy System Preferences. This app needs to be on the Accessibility whitelist in order to process global mouse events. Please open the Accessibility panel below and add the app to the whitelist.", appDescription];
            
            NSMutableAttributedString* string = [[NSMutableAttributedString alloc] initWithString:text attributes:alertAttributes];
            [string addAttribute:NSFontAttributeName value:boldFont range:[text rangeOfString:appDescription]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:regularAttributes]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:smallReturnAttributes]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:copyright attributes:regularAttributes]];
            
            [self.text.textStorage setAttributedString:string];
        } break;
        case MenuModeDonation: {
            NSString* text = [NSString stringWithFormat:@"Thanks for using %@!\nIf you find this utility useful, please consider making a purchase through the Amazon affiliate link on the website below. It won't cost you an extra cent! 😊", appDescription];
            
            NSMutableAttributedString* string = [[NSMutableAttributedString alloc] initWithString:text attributes:regularAttributes];
            [string addAttribute:NSFontAttributeName value:boldFont range:[text rangeOfString:appDescription]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:regularAttributes]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:smallReturnAttributes]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:copyright attributes:regularAttributes]];
            
            [self.text.textStorage setAttributedString:string];
        } break;
        case MenuModeNormal: {
            NSString* text = [NSString stringWithFormat:@"Thanks for using %@!", appDescription];
            
            NSMutableAttributedString* string = [[NSMutableAttributedString alloc] initWithString:text attributes:regularAttributes];
            [string addAttribute:NSFontAttributeName value:boldFont range:[text rangeOfString:appDescription]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:regularAttributes]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:smallReturnAttributes]];
            [string appendAttributedString:[[NSAttributedString alloc] initWithString:copyright attributes:regularAttributes]];
            
            [self.text.textStorage setAttributedString:string];
        } break;
    }
    
    [self setNeedsLayout:YES];
}

-(instancetype) initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    
    if (self) {
        self.text = [NSTextView new];
        self.text.backgroundColor = NSColor.clearColor;
        [self.text setEditable:NO];
        [self.text setSelectable:NO];
        [self addSubview:self.text];
        
        self.menuMode = MenuModeNormal;
    }
    
    return self;
}

- (void)sizeToFit {
    NSSize sz = self.bounds.size;
    self.text.textContainerInset = NSMakeSize(17, 0);
    [self.text setFrameSize:NSMakeSize(sz.width, 1000)];
    [self.text sizeToFit];
    sz.height = NSHeight(self.text.bounds);
   
    [self setFrameSize:sz];
}

- (void)layout {
    [super layout];
    self.text.frame = self.bounds;
}

@end
