// --mirror-frame: menu bar and window chrome laid out after iPhone Mirroring.
// SDL3 builds only the app and Window menus; everything a mirror can do lives
// behind shortcuts with nothing on screen naming them.
//
// Items push synthetic SDL key events carrying the shortcut modifier, which is
// the same path a real shortcut takes through the input manager. The three
// size items have no shortcut behind them and resize the NSWindow directly.
//
// Key equivalents are ⌘ chords only. AppKit claims them before SDL sees the
// key: with a ⌘ shortcut modifier the item replaces scrcpy's own chord and
// sends the same action, otherwise ⌘ reaches the device only as META, which
// Android apps ignore. ⌃ chords stay the device's.
//
// The window is iPhone Mirroring's frame: the video is a panel with rounded
// corners, inset 8 pt at the sides and below and 38 pt above, in a clear
// window. The hover chrome fills the margin and fades in only while the pointer
// is in the top strip: see installchrome(). The title stays set, hidden, so
// window managers still match the window on it.
//
// SDL takes its window size from -contentRectForFrameRect: and its mouse
// position from -locationInWindow, so both are shifted by the inset for framed
// windows: see hookgeometry().
//
// Icons: iPhone Mirroring's own symbols where they are public
// (iphone.app.switcher, square.resize*). Its Home Screen glyph, app.grid.3x3,
// ships only inside ScreenContinuityUI's asset catalog, so homeglyph() draws it.

#include "mirror_frame.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <SDL3/SDL.h>

#include "adb/adb.h"
#include "util/log.h"

// The tag packs a 32-bit SDL_Keycode in the low bits and the shift flag above
// it; arrow keycodes carry SDLK_SCANCODE_MASK (bit 30), so no low bit is spare.
#define TAG(key, shift) ((NSInteger)(key) | ((NSInteger)(shift) << 40))

static const NSEventModifierFlags CMD = NSEventModifierFlagCommand;

// The panel's place in the window, iPhone Mirroring's 406x890 around 390x844.
static const CGFloat SIDE = 8, TOP = 38;

// One modifier of the configured shortcut set, as an SDL_Keymod.
static SDL_Keymod shortcutmod;

// The device's content size, rotation applied; see sc_mirror_frame_set_content_size().
static struct sc_size content;

// The framed window, once restyle() has made it one.
static __weak NSWindow *mirror;

static void pushkey(SDL_Keycode key, bool shift) {
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    if (!windows) {
        return;
    }
    if (count) {
        SDL_Event event = {0};
        event.key.type = SDL_EVENT_KEY_DOWN;
        event.key.timestamp = SDL_GetTicksNS();
        event.key.windowID = SDL_GetWindowID(windows[0]);
        event.key.scancode = SDL_GetScancodeFromKey(key, NULL);
        event.key.key = key;
        event.key.mod = shortcutmod | (shift ? SDL_KMOD_LSHIFT : 0);
        event.key.down = true;
        SDL_PushEvent(&event);
        // Device keys are injected as a down/up pair: scrcpy forwards the press
        // on SDL_EVENT_KEY_DOWN and the release on SDL_EVENT_KEY_UP, and Android
        // acts on the release. Window-level shortcuts test `down` and ignore the
        // second event.
        event.key.type = SDL_EVENT_KEY_UP;
        event.key.down = false;
        SDL_PushEvent(&event);
    }
    SDL_free(windows);
}

// A grey from its 0-255 sRGB channel value.
static NSColor *gray(int v) {
    return [NSColor colorWithSRGBRed:v / 255.0 green:v / 255.0 blue:v / 255.0 alpha:1];
}

// iPhone Mirroring's app.grid.3x3: 2.9 pt tiles on a 4 pt pitch. The canvas is a
// point taller than the grid, empty at the top, so centring it drops the grid
// onto iPhone Mirroring's pixel rows.
static NSImage *homeglyph(void) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(11, 12) flipped:NO
                             drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor setFill];
        for (int row = 0; row < 3; row++) {
            for (int col = 0; col < 3; col++) {
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(col * 4, row * 4, 2.9, 2.9)
                                                 xRadius:0.75 yRadius:0.75] fill];
            }
        }
        return YES;
    }];
    image.template = YES;
    image.accessibilityDescription = @"Home Screen";
    return image;
}

// The chrome's backing, filling the whole window around the panel: sRGB 0x28,
// which a capture reads back as iPhone Mirroring's #353535, under a 1 pt top
// edge in two half-point bands, lighter above. Continuous corners, 19.75 pt at
// the top and bottomRadius below; the mask is two halves because one layer
// takes one corner radius.
@interface MirrorBacking : NSView
@property (nonatomic) CGFloat bottomRadius;
@end

@implementation MirrorBacking {
    CALayer *_upper, *_lower, *_light, *_dark;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = gray(0x28).CGColor;
        CALayer *mask = [CALayer layer];
        _upper = [CALayer layer];
        _upper.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        _upper.cornerRadius = 19.75;
        _lower = [CALayer layer];
        _lower.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        for (CALayer *half in @[_upper, _lower]) {
            half.backgroundColor = NSColor.blackColor.CGColor;
            half.cornerCurve = kCACornerCurveContinuous;
            [mask addSublayer:half];
        }
        self.layer.mask = mask;
        _light = [CALayer layer];
        _light.backgroundColor = gray(0x53).CGColor;
        _dark = [CALayer layer];
        _dark.backgroundColor = gray(0x3F).CGColor;
        [self.layer addSublayer:_light];
        [self.layer addSublayer:_dark];
    }
    return self;
}

- (void)setBottomRadius:(CGFloat)radius {
    _bottomRadius = radius;
    [self reshape];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self reshape];
}

- (void)reshape {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.mask.frame = self.bounds;
    _upper.frame = CGRectMake(0, h / 2 - 1, w, h / 2 + 1);
    _lower.frame = CGRectMake(0, 0, w, h / 2 + 1);
    _lower.cornerRadius = _bottomRadius;
    _light.frame = CGRectMake(0, h - 0.5, w, 0.5);
    _dark.frame = CGRectMake(0, h - 1, w, 0.5);
    [CATransaction commit];
}

@end

// Reports the pointer entering and leaving the top strip. Never takes a click:
// the title bar and the chrome's buttons own those.
@interface MirrorStrip : NSView
@property (copy) void (^hover)(BOOL inside);
@end

@implementation MirrorStrip

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
                     | NSTrackingInVisibleRect
               owner:self
            userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    self.hover(YES);
}

- (void)mouseExited:(NSEvent *)event {
    self.hover(NO);
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end

// iPhone Mirroring's hover: a pill of white at 7.5% behind the glyph, which
// brightens from #9e to #e1. The pill is the button's own bounds. A press
// doubles the pill's white and leaves the glyph lit until the button lets go.
@interface MirrorButton : NSButton {
    // Only this one is swapped on update: the tooltip rides on AppKit's own area.
    NSTrackingArea *area;
}
@end

@implementation MirrorButton

// A symbol image gives the button alignment insets, and constraints size the
// alignment rect: the frame, and the pill with it, would stand taller than set.
- (NSEdgeInsets)alignmentRectInsets {
    return NSEdgeInsetsZero;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (area) {
        [self removeTrackingArea:area];
    }
    area = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
                     | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:area];
}

- (void)layout {
    [super layout];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}

- (void)hover:(BOOL)inside {
    self.layer.backgroundColor = inside ? [NSColor colorWithWhite:1 alpha:0.075].CGColor : nil;
    self.contentTintColor = gray(inside ? 0xE1 : 0x9E);
}

- (void)mouseEntered:(NSEvent *)event {
    [self hover:YES];
}

// -[NSButton mouseDown:] tracks the press until the button is let go.
- (void)mouseDown:(NSEvent *)event {
    self.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.15].CGColor;
    self.contentTintColor = gray(0xE1);
    [super mouseDown:event];
    NSPoint point = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [self hover:NSMouseInRect(point, self.bounds, self.flipped)];
}

- (void)mouseExited:(NSEvent *)event {
    [self hover:NO];
}

@end

// adb against the mirrored device, through scrcpy's adb: $ADB or adb on PATH.
// `done` runs on the main thread, `out` takes stdout when given.
static NSString *serial;

static void adb(NSArray<NSString *> *args, id out, void (^done)(NSTask *task)) {
    NSString *exe = @(sc_adb_get_executable());
    NSTask *task = [NSTask new];
    NSArray *head = serial ? @[@"-s", serial] : @[];
    if ([exe containsString:@"/"]) {
        task.executableURL = [NSURL fileURLWithPath:exe];
    } else {
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
        head = [@[exe] arrayByAddingObjectsFromArray:head];
    }
    task.arguments = [head arrayByAddingObjectsFromArray:args];
    task.standardOutput = out ?: NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.terminationHandler = ^(NSTask *t) {
        if (done) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(t); });
        }
    };
    if (![task launchAndReturnError:nil] && done) {
        done(nil);
    }
}

// A serial with a port or an mDNS service name is a wireless link.
static BOOL wireless(void) {
    return [serial containsString:@":"] || [serial containsString:@"._adb._tcp"];
}

// Device state, read each time the Device menu opens so changes made on the
// device show. Rotation is `wm user-rotation`'s answer: "lock 0" natural,
// "lock 1" a quarter turn, "free" auto-rotate. The front app is the top
// resumed activity's package. Charge limit is LineageOS charging control, in
// its own provider; elsewhere both its lines come back empty and the item hides.
static BOOL panellit, touches, chargecap, airplane, wifi, bluetooth;
static int brightness = -1;
static NSString *rotation, *frontapp, *caplimit;
static NSMenu *devicemenu;
static NSMenuItem *batteryitem, *stopitem, *capitem;
static NSString *const ROTATIONS[] = {@"lock 0", @"lock 1", @"free"};
static const int LEVELS[] = {20, 96, 255};
static NSString *const POWER[] = {@"Reboot", @"Reboot to Recovery", @"Shut Down"};

// One line per value, in this order: show touches, user rotation, front app,
// battery level, powered count, charge limit on, charge limit percent,
// brightness, airplane mode, Wi-Fi, Bluetooth.
static NSString *const STATE =
    @"lv() { content query --uri content://lineagesettings/system --projection value"
     " --where \"name='$1'\" 2>/dev/null | sed -n 's/.*value=//p'; };"
     " settings get system show_touches; wm user-rotation;"
     " echo \"$(dumpsys activity activities 2>/dev/null"
     " | sed -n '/topResumedActivity=/{s/.* u[0-9]* \\([^/]*\\)\\/.*/\\1/p;q;}')\";"
     " dumpsys battery | sed -n 's/^  level: //p'; dumpsys battery | grep -c 'powered: true';"
     " echo \"$(lv charging_control_enabled)\"; echo \"$(lv charging_control_charging_limit)\";"
     " settings get system screen_brightness; settings get global airplane_mode_on;"
     " settings get global wifi_on; settings get global bluetooth_on";

static void readstate(void) {
    NSPipe *pipe = [NSPipe pipe];
    adb(@[@"shell", STATE], pipe, ^(NSTask *task) {
        NSString *text = [[NSString alloc] initWithData:pipe.fileHandleForReading.readDataToEndOfFile
                                               encoding:NSUTF8StringEncoding];
        NSArray *lines = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                          componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (lines.count < 11) {
            return;
        }
        NSCharacterSet *space = NSCharacterSet.whitespaceCharacterSet;
        touches = [lines[0] isEqualToString:@"1"];
        rotation = [lines[1] stringByTrimmingCharactersInSet:space];
        frontapp = [lines[2] stringByTrimmingCharactersInSet:space];
        chargecap = [lines[5] intValue] == 1;
        caplimit = [lines[6] stringByTrimmingCharactersInSet:space];
        brightness = [lines[7] intValue];
        airplane = [lines[8] intValue] == 1;
        wifi = [lines[9] intValue] == 1;
        bluetooth = [lines[10] intValue] == 1;
        stopitem.title = frontapp.length ? [@"Force Stop " stringByAppendingString:frontapp]
                                         : @"Force Stop App";
        capitem.hidden = caplimit.length == 0;
        batteryitem.title = [NSString stringWithFormat:@"Battery %@%%, %@%@",
                             [lines[3] stringByTrimmingCharactersInSet:space],
                             [lines[4] intValue] ? @"on power" : @"on battery",
                             chargecap && caplimit.length
                                 ? [NSString stringWithFormat:@", held at %@%%", caplimit] : @""];
        [devicemenu update];
    });
}

static void chime(NSTask *task, NSString *sound) {
    if (task && task.terminationStatus == 0) {
        [[NSSound soundNamed:sound] play];
    } else {
        NSBeep();
    }
}

static void lineageput(NSString *name, NSString *value) {
    adb(@[@"shell", @"content", @"insert", @"--uri", @"content://lineagesettings/system",
          @"--bind", [@"name:s:" stringByAppendingString:name],
          @"--bind", [@"value:s:" stringByAppendingString:value]], nil, nil);
}

static NSMenuItem *submenu(NSMenu *menu, NSString *title, NSString *symbol) {
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    holder.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    holder.submenu = [[NSMenu alloc] initWithTitle:title];
    [menu addItem:holder];
    return holder;
}

static NSControlStateValue checked(BOOL on) {
    return on ? NSControlStateValueOn : NSControlStateValueOff;
}

@interface ScrcpyMenu : NSObject <NSMenuDelegate>
@end

@implementation ScrcpyMenu

// Menu items and the chrome's buttons both carry a TAG.
- (void)send:(id)sender {
    NSInteger tag = [sender tag];
    pushkey((SDL_Keycode)(tag & 0xffffffffLL), (tag >> 40) & 1);
}

// Three fixed window heights, iPhone Mirroring's own at Larger, Actual Size and
// Smaller (406x890, 316x696, 212x471), whatever the device: a phone, a tablet
// and a landscape display stand as tall as an iPhone mirror beside them. The
// item's tag indexes HEIGHTS from 1; the last one chosen is re-applied whenever
// the content size changes, as after a rotation.
static const CGFloat HEIGHTS[] = {890, 696, 471};
static NSInteger preset = 1;
// The window height fitheight() last set, which the dimmed item reports.
static CGFloat fitted;

// Panel heights at which the device's pixels scale to whole points in both
// directions are multiples of h / gcd(w, h): 5 for 1200x2000, 20 for 1080x2400.
// The panel snaps to the nearest one, never taller than the screen allows.
static CGFloat snap(CGFloat height, CGFloat limit) {
    unsigned w = content.width, h = content.height;
    while (w) {
        unsigned r = h % w;
        h = w;
        w = r;
    }
    CGFloat step = content.height / h;
    // ponytail: a resolution with no whole-point height near the target keeps
    // the unsnapped one; one pixel of stretch there is below what a mirror shows.
    if (step > 24) {
        return fmin(height, limit);
    }
    CGFloat snapped = round(height / step) * step;
    return snapped <= limit ? snapped : floor(limit / step) * step;
}

static void fitheight(NSWindow *window) {
    if (!content.width || !content.height) {
        return;
    }
    NSRect frame = window.frame;
    NSRect visible = window.screen.visibleFrame;
    // The margin around the panel is fixed.
    NSSize panel = [window contentRectForFrameRect:frame].size;
    CGFloat mw = frame.size.width - panel.width, mh = frame.size.height - panel.height;
    CGFloat aspect = (CGFloat) content.width / content.height;

    CGFloat limit = fmin(visible.size.height - mh, (visible.size.width - mw) / aspect);
    CGFloat height = snap(HEIGHTS[preset - 1] - mh, limit);
    frame.size.height = height + mh;
    frame.size.width = round(height * aspect) + mw;
    // Keep the top edge where it is, then pull the window back on screen.
    frame.origin.y = NSMaxY(window.frame) - frame.size.height;
    frame.origin.x = fmax(visible.origin.x, fmin(frame.origin.x, NSMaxX(visible) - frame.size.width));
    frame.origin.y = fmax(visible.origin.y, fmin(frame.origin.y, NSMaxY(visible) - frame.size.height));
    fitted = frame.size.height;
    [window setFrame:frame display:YES animate:NO];
}

- (void)zoom:(NSMenuItem *)item {
    NSWindow *window = NSApp.keyWindow ?: NSApp.windows.firstObject;
    if (window) {
        preset = item.tag;
        fitheight(window);
    }
}

// The size the window stands at is dimmed, as in iPhone Mirroring.
// Device Screen: the screen-off shortcut and its shift form blank and relight
// the device panel, mirroring on either way. The device reports no panel
// state, so this is the last one sent, starting from --turn-screen-off. A
// touch on the device or the Power item relights the panel behind it; the next
// pick then resends the state already showing, and the one after acts.
- (void)panel:(id)sender {
    panellit = !panellit;
    pushkey(SDLK_O, panellit);
}

- (void)touches:(id)sender {
    touches = !touches;
    adb(@[@"shell", @"settings", @"put", @"system", @"show_touches", touches ? @"1" : @"0"], nil, nil);
}

- (void)rotate:(NSMenuItem *)item {
    rotation = ROTATIONS[item.tag];
    adb([@[@"shell", @"wm", @"user-rotation"]
         arrayByAddingObjectsFromArray:[rotation componentsSeparatedByString:@" "]], nil, nil);
}

// Manual mode, then the level: auto-brightness would move it straight back.
- (void)brightness:(NSMenuItem *)item {
    brightness = LEVELS[item.tag];
    adb(@[@"shell", [NSString stringWithFormat:
          @"settings put system screen_brightness_mode 0; settings put system screen_brightness %d",
          brightness]], nil, nil);
}

// The device's own framebuffer at full resolution, not the mirror window.
- (void)screenshot:(id)sender {
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *name = mirror.title.length ? mirror.title : @"scrcpy";
    NSString *path = [NSString stringWithFormat:@"%@/Downloads/%@ %@.png", NSHomeDirectory(),
                      name, [format stringFromDate:NSDate.date]];
    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    adb(@[@"exec-out", @"screencap", @"-p"], out, ^(NSTask *task) {
        [out closeFile];
        if (!task || task.terminationStatus != 0) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
        chime(task, @"Grab");
    });
}

// .apk installs, anything else lands in the device's Download folder. Not
// modal: a modal panel would stall SDL's event loop and freeze the mirror.
- (void)sendfile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = YES;
    panel.prompt = @"Send";
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) {
            return;
        }
        for (NSURL *url in panel.URLs) {
            NSArray *args = [url.pathExtension.lowercaseString isEqualToString:@"apk"]
                ? @[@"install", @"-r", url.path]
                : @[@"push", url.path, @"/sdcard/Download/"];
            adb(args, nil, ^(NSTask *task) { chime(task, @"Glass"); });
        }
    }];
}

- (void)forcestop:(id)sender {
    if (frontapp.length) {
        adb(@[@"shell", @"am", @"force-stop", frontapp], nil, nil);
    }
}

// Charge Limit submenu: tag 0 is Off, any other tag is the percent to hold at.
- (void)chargecap:(NSMenuItem *)item {
    chargecap = item.tag != 0;
    if (chargecap) {
        caplimit = [NSString stringWithFormat:@"%ld", (long)item.tag];
        lineageput(@"charging_control_charging_limit", caplimit);
    }
    lineageput(@"charging_control_enabled", chargecap ? @"1" : @"0");
}

- (void)wifi:(id)sender {
    wifi = !wifi;
    adb(@[@"shell", @"svc", @"wifi", wifi ? @"enable" : @"disable"], nil, nil);
}

- (void)bluetooth:(id)sender {
    bluetooth = !bluetooth;
    adb(@[@"shell", @"svc", @"bluetooth", bluetooth ? @"enable" : @"disable"], nil, nil);
}

- (void)airplane:(id)sender {
    airplane = !airplane;
    adb(@[@"shell", @"cmd", @"connectivity", @"airplane-mode", airplane ? @"enable" : @"disable"], nil, nil);
}

// Reboot, Reboot to Recovery, Shut Down, after a confirmation. The mirror ends
// with the link. A device on USB power may come back up in charge mode after a
// shutdown rather than stay off.
- (void)power:(NSMenuItem *)item {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%@ %@?", POWER[item.tag],
                         mirror.title.length ? mirror.title : @"the device"];
    [alert addButtonWithTitle:POWER[item.tag]];
    [alert addButtonWithTitle:@"Cancel"];
    alert.buttons.firstObject.hasDestructiveAction = YES;
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    NSArray *args[] = {@[@"reboot"], @[@"reboot", @"recovery"], @[@"shell", @"reboot", @"-p"]};
    adb(args[item.tag], nil, nil);
}

- (void)menuWillOpen:(NSMenu *)menu {
    readstate();
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(panel:)) {
        item.state = checked(panellit);
    } else if (action == @selector(touches:)) {
        item.state = checked(touches);
    } else if (action == @selector(rotate:)) {
        item.state = checked([rotation isEqualToString:ROTATIONS[item.tag]]);
    } else if (action == @selector(brightness:)) {
        item.state = checked(brightness == LEVELS[item.tag]);
    } else if (action == @selector(chargecap:)) {
        item.state = checked(item.tag ? chargecap && caplimit.intValue == item.tag : !chargecap);
    } else if (action == @selector(bluetooth:)) {
        item.state = checked(bluetooth);
    } else if (action == @selector(wifi:) || action == @selector(airplane:)) {
        // Both would cut the link a wireless mirror runs on.
        item.state = checked(action == @selector(wifi:) ? wifi : airplane);
        return !wireless();
    } else if (action == @selector(forcestop:)) {
        return frontapp.length > 0;
    }
    return item.action != @selector(zoom:) || item.tag != preset
        || fabs(mirror.frame.size.height - fitted) > 0.5;
}

- (void)help:(NSMenuItem *)item {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"https://github.com/Genymobile/scrcpy/blob/master/doc/shortcuts.md"]];
}

@end

static ScrcpyMenu *target;

static NSButton *chromebutton(NSString *label, NSImage *image, NSInteger tag) {
    NSButton *button = [MirrorButton buttonWithImage:image target:target action:@selector(send:)];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    // Reads back from a capture as iPhone Mirroring's #adadad.
    button.contentTintColor = gray(0x9E);
    button.toolTip = label;
    button.wantsLayer = YES;
    // The press look is MirrorButton's, not the cell's brightened glyph.
    ((NSButtonCell *)button.cell).highlightsBy = NSNoCellMask;
    button.accessibilityLabel = label;
    button.tag = tag;
    // SDL's view keeps first responder; it is what feeds the device keys.
    button.refusesFirstResponder = YES;
    return button;
}

// The window's content view: SDL's view at the inset, the chrome around it.
// AppKit sizes this view both from -contentRectForFrameRect: and from the full
// frame, so the panel is placed from its bounds rather than autoresized.
@interface MirrorFrame : NSView
@property (weak) NSView *panel;
@end

@implementation MirrorFrame

- (void)resizeSubviewsWithOldSize:(NSSize)size {
    [super resizeSubviewsWithOldSize:size];
    NSSize bounds = self.bounds.size;
    self.panel.frame = NSMakeRect(SIDE, SIDE, bounds.width - 2 * SIDE, bounds.height - SIDE - TOP);
}

@end

// Framed windows are SDL's, once restyle() has set the full-size-content bit.
static BOOL framed(NSWindow *window) {
    return [NSStringFromClass(window.class) hasPrefix:@"SDL"]
        && (window.styleMask & NSWindowStyleMaskFullSizeContentView);
}

// Adds sel to cls, or replaces it where cls defines it itself; returns the
// implementation it had, inherited or not.
static IMP hook(Class cls, SEL sel, IMP imp) {
    Method method = class_getInstanceMethod(cls, sel);
    IMP orig = method_getImplementation(method);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(method))) {
        method_setImplementation(method, imp);
    }
    return orig;
}

static IMP contentrect, framerect, location;
static int shifting;

// The window's size is the View menu's alone, as iPhone Mirroring's is:
// Accessibility reports it fixed and drops writes, so a tiling window manager
// keeps it at its own size. From creation, not from restyle(): a tiling manager
// sizes a new window to its tile before it is ever key.
// SDL's own resizes, as after a rotation, go through -setFrame: and still land.
static BOOL axsizesettable(NSWindow *self, SEL cmd) {
    return NO;
}

static void axsetsize(NSWindow *self, SEL cmd, id value) {
}

// No fullscreen of any kind: the frame, the tiling and the rotation re-fit all
// assume a window the size the View menu gave it. The green button, AppKit's
// Enter Full Screen item and SDL's own fullscreen all end in -toggleFullScreen:.
static void nofullscreen(NSWindow *self, SEL cmd, id sender) {
}

// AppKit answers YES for a window without NSWindowStyleMaskResizable. SDL reads
// that as maximized, and scrcpy defers every content resize while maximized, so
// a rotation would leave the window letterboxed.
static BOOL notzoomed(NSWindow *self, SEL cmd) {
    return NO;
}

static NSRect insetcontent(NSWindow *self, SEL cmd, NSRect frame) {
    NSRect rect = ((NSRect (*)(id, SEL, NSRect))contentrect)(self, cmd, frame);
    return framed(self) ? NSMakeRect(rect.origin.x + SIDE, rect.origin.y + SIDE,
                                     rect.size.width - 2 * SIDE, rect.size.height - SIDE - TOP)
                        : rect;
}

static NSRect outsetframe(NSWindow *self, SEL cmd, NSRect content) {
    if (framed(self)) {
        content = NSMakeRect(content.origin.x - SIDE, content.origin.y - SIDE,
                             content.size.width + 2 * SIDE, content.size.height + SIDE + TOP);
    }
    return ((NSRect (*)(id, SEL, NSRect))framerect)(self, cmd, content);
}

// Panel coordinates, but only while SDL's own mouse handlers run: AppKit's hit
// testing and tracking areas keep reading window coordinates.
static NSPoint panellocation(NSEvent *self, SEL cmd) {
    NSPoint point = ((NSPoint (*)(id, SEL))location)(self, cmd);
    if (shifting && framed(self.window)) {
        point.x -= SIDE;
        point.y -= SIDE;
    }
    return point;
}

// SDL sizes the window, places it and maps the pointer through these, so it
// sees the panel as the whole window. Installed before SDL builds its window;
// framed() leaves every window alone until restyle() marks it.
static void hookgeometry(void) {
    Class window = objc_getClass("SDL3Window");
    Class listener = objc_getClass("SDL3Cocoa_WindowListener");
    if (!window || !listener) {
        return;
    }
    contentrect = hook(window, @selector(contentRectForFrameRect:), (IMP)insetcontent);
    framerect = hook(window, @selector(frameRectForContentRect:), (IMP)outsetframe);
    location = hook(NSEvent.class, @selector(locationInWindow), (IMP)panellocation);
    hook(window, NSSelectorFromString(@"accessibilityIsSizeAttributeSettable"), (IMP)axsizesettable);
    hook(window, NSSelectorFromString(@"accessibilitySetSizeAttribute:"), (IMP)axsetsize);
    hook(window, @selector(isZoomed), (IMP)notzoomed);
    hook(window, @selector(toggleFullScreen:), (IMP)nofullscreen);
    for (NSString *name in @[@"mouseDown:", @"rightMouseDown:", @"otherMouseDown:",
                             @"mouseUp:", @"rightMouseUp:", @"otherMouseUp:",
                             @"mouseMoved:", @"mouseDragged:", @"rightMouseDragged:",
                             @"otherMouseDragged:", @"scrollWheel:", @"magnifyWithEvent:"]) {
        SEL sel = NSSelectorFromString(name);
        __block IMP orig;
        orig = hook(listener, sel, imp_implementationWithBlock(^(id self, NSEvent *event) {
            shifting++;
            ((void (*)(id, SEL, NSEvent *))orig)(self, sel, event);
            shifting--;
        }));
    }
}

// iPhone Mirroring's hover chrome, measured off `screencapture -l` of its window
// at 2x: traffic lights centred 18.75 pt down on a 23 pt pitch from 15.75 pt in,
// Home Screen and App Switcher centred 75.75 and 28.5 pt in from the right, all
// at alpha 0 until the pointer is over the 38 pt strip. AppKit owns the title
// bar's own lights' layout, so those stay hidden and free-standing ones sit on
// the measured centres. The lights draw 14 pt with a ring because scrcpy is
// stamped SDK 26.
//
// The panel's corners are 48 pt at 844 pt tall, scaled with its long side, and
// the backing's bottom corners 51.5 pt at that size.
static void installchrome(NSWindow *window, NSView *content, NSView *panel) {
    NSMutableArray<NSView *> *chrome = [NSMutableArray array];
    NSMutableArray<NSLayoutConstraint *> *pins = [NSMutableArray array];
    void (^add)(NSView *) = ^(NSView *view) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view positioned:NSWindowAbove relativeTo:nil];
    };

    MirrorBacking *backing = [[MirrorBacking alloc] initWithFrame:content.bounds];
    backing.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:backing positioned:NSWindowBelow relativeTo:nil];
    [chrome addObject:backing];

    panel.wantsLayer = YES;
    panel.layer.masksToBounds = YES;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    void (^round)(void) = ^{
        CGFloat radius = 48 * fmax(panel.bounds.size.width, panel.bounds.size.height) / 844;
        panel.layer.cornerRadius = radius;
        backing.bottomRadius = radius * 51.5 / 48;
    };
    round();
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification
                                                    object:window
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
        round();
        [note.object invalidateShadow];
    }];

    MirrorStrip *strip = [[MirrorStrip alloc] initWithFrame:NSZeroRect];
    add(strip);
    [pins addObjectsFromArray:@[
        [strip.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [strip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [strip.topAnchor constraintEqualToAnchor:content.topAnchor],
        [strip.heightAnchor constraintEqualToConstant:TOP],
    ]];

    for (NSWindowButton type = NSWindowCloseButton; type <= NSWindowZoomButton; type++) {
        [window standardWindowButton:type].hidden = YES;
        NSButton *light = [NSWindow standardWindowButton:type forStyleMask:window.styleMask];
        add(light);
        [pins addObjectsFromArray:@[
            [light.centerXAnchor constraintEqualToAnchor:content.leadingAnchor constant:15.75 + 23 * type],
            [light.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:18.75],
        ]];
        [chrome addObject:light];
    }
    // Tooltips show on hover whichever app is active, as in iPhone Mirroring.
    window.allowsToolTipsWhenApplicationIsInactive = YES;
    // No fullscreen and no zoom, so the green light draws disabled.
    ((NSButton *)chrome.lastObject).enabled = NO;

    NSImage *switcher = [[NSImage imageWithSystemSymbolName:@"iphone.app.switcher"
                                   accessibilityDescription:@"App Switcher"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration
            configurationWithPointSize:13 weight:NSFontWeightRegular]];
    NSArray *buttons = @[chromebutton(@"Home Screen", homeglyph(), TAG(SDLK_H, 0)),
                         chromebutton(@"App Switcher", switcher, TAG(SDLK_S, 0))];
    // Centres and hover pills, measured off iPhone Mirroring's at 2x.
    const CGFloat insets[] = {75.75, 28.5}, middles[] = {18.75, 19}, widths[] = {38, 40.5}, heights[] = {21, 24};
    for (NSUInteger i = 0; i < buttons.count; i++) {
        NSButton *button = buttons[i];
        add(button);
        [pins addObjectsFromArray:@[
            [button.centerXAnchor constraintEqualToAnchor:content.trailingAnchor constant:-insets[i]],
            [button.centerYAnchor constraintEqualToAnchor:content.topAnchor constant:middles[i]],
            [button.widthAnchor constraintEqualToConstant:widths[i]],
            [button.heightAnchor constraintEqualToConstant:heights[i]],
        ]];
        [chrome addObject:button];
    }
    [NSLayoutConstraint activateConstraints:pins];

    for (NSView *view in chrome) {
        view.alphaValue = 0;
    }
    __weak NSWindow *weak = window;
    strip.hover = ^(BOOL inside) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.2;
            for (NSView *view in chrome) {
                view.animator.alphaValue = inside ? 1 : 0;
            }
        } completionHandler:^{
            // The shadow is cut from the window's alpha; the backing changes it.
            [weak invalidateShadow];
        }];
    };
}

// Runs on every key and visibility change of every window, so it has to be a
// no-op after the first pass; framed() is the marker. Without the geometry
// hooks SDL would map clicks across the margin, so no hooks, no frame.
//
// SDL's view moves into a MirrorFrame and keeps the listener as its next
// responder, since that is where SDL's mouse handlers live. The window
// grows by the margin around the panel SDL sized, so SDL sees no resize.
// Not resizable: its edges do not drag, see axsizesettable().
static void restyle(NSWindow *window) {
    if (!contentrect || ![NSStringFromClass(window.class) hasPrefix:@"SDL"] || framed(window)) {
        return;
    }
    NSRect panel = [window contentRectForFrameRect:window.frame];
    window.styleMask = (window.styleMask | NSWindowStyleMaskFullSizeContentView)
                     & ~NSWindowStyleMaskResizable;
    window.collectionBehavior = (window.collectionBehavior
                                 & ~(NSWindowCollectionBehaviorFullScreenPrimary
                                     | NSWindowCollectionBehaviorFullScreenAuxiliary))
                              | NSWindowCollectionBehaviorFullScreenNone;
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.backgroundColor = NSColor.clearColor;
    window.opaque = NO;

    NSView *sdl = window.contentView;
    NSResponder *listener = sdl.nextResponder;
    MirrorFrame *content = [[MirrorFrame alloc] initWithFrame:NSZeroRect];
    window.contentView = content;
    content.panel = sdl;
    [content addSubview:sdl];
    sdl.nextResponder = listener;
    [window makeFirstResponder:sdl];
    [window setFrame:[window frameRectForContentRect:panel] display:YES];
    [content resizeSubviewsWithOldSize:content.bounds.size];
    installchrome(window, content, sdl);
    mirror = window;
    fitheight(window);
}

static void additem(NSMenu *menu, NSString *title, SEL action, NSInteger tag,
                    NSString *symbol, NSString *key, NSEventModifierFlags mods) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.keyEquivalentModifierMask = mods;
    item.target = target;
    item.tag = tag;
    if (symbol) {
        item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    }
    [menu addItem:item];
}

static NSMenu *addmenu(NSMenu *bar, NSString *title, NSInteger index) {
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    holder.submenu = menu;
    [bar insertItem:holder atIndex:index];
    return menu;
}

static void buildmenus(void) {
    NSMenu *bar = NSApp.mainMenu;
    if (!bar || bar.numberOfItems == 0) {
        return;
    }
    SEL send = @selector(send:);
    SEL zoom = @selector(zoom:);

    // App, Edit, View, Device, Window, Help. Index 1 is right after the app
    // menu SDL created; its Window menu ends up before Help, as the HIG orders it.
    NSMenu *edit = addmenu(bar, @"Edit", 1);
    additem(edit, @"Cut", send, TAG(SDLK_X, 0), @"scissors", @"x", CMD);
    additem(edit, @"Copy", send, TAG(SDLK_C, 0), @"document.on.document", @"c", CMD);
    additem(edit, @"Paste", send, TAG(SDLK_V, 0), @"document.on.clipboard", @"v", CMD);
    additem(edit, @"Paste as Keystrokes", send, TAG(SDLK_V, 1), @"keyboard", @"v",
            CMD | NSEventModifierFlagOption | NSEventModifierFlagShift);

    // iPhone Mirroring's View menu, block for block: three navigation items,
    // then the three sizes. Notifications takes Spotlight's slot.
    NSMenu *view = addmenu(bar, @"View", 2);
    additem(view, @"Home Screen", send, TAG(SDLK_H, 0), nil, @"1", CMD);
    view.itemArray.lastObject.image = homeglyph();
    additem(view, @"App Switcher", send, TAG(SDLK_S, 0), @"iphone.app.switcher", @"2", CMD);
    additem(view, @"Notifications", send, TAG(SDLK_N, 0), @"bell", @"3", CMD);
    [view addItem:[NSMenuItem separatorItem]];
    additem(view, @"Larger", zoom, 1, @"square.resize.up", @"+", CMD);
    additem(view, @"Actual Size", zoom, 2, @"square.resize", @"0", CMD);
    additem(view, @"Smaller", zoom, 3, @"square.resize.down", @"-", CMD);
    [view addItem:[NSMenuItem separatorItem]];
    additem(view, @"Fit to Window", send, TAG(SDLK_W, 0), @"crop", nil, 0);
    additem(view, @"Rotate Left", send, TAG(SDLK_LEFT, 0), @"rotate.left", nil, 0);
    additem(view, @"Rotate Right", send, TAG(SDLK_RIGHT, 0), @"rotate.right", nil, 0);

    NSMenu *device = addmenu(bar, @"Device", 3);
    additem(device, @"Back", send, TAG(SDLK_B, 0), @"chevron.backward", @"[", CMD);
    additem(device, @"Menu", send, TAG(SDLK_M, 0), @"line.3.horizontal", nil, 0);
    additem(device, @"Hide Notifications", send, TAG(SDLK_N, 1), @"bell.slash", nil, 0);
    [device addItem:[NSMenuItem separatorItem]];
    additem(device, @"Rotate Device", send, TAG(SDLK_R, 0), @"rectangle.portrait.rotate", nil, 0);
    NSMenu *rotations = submenu(device, @"Rotation Lock", @"lock.rotation").submenu;
    additem(rotations, @"Natural", @selector(rotate:), 0, @"rectangle.portrait", nil, 0);
    additem(rotations, @"Quarter Turn", @selector(rotate:), 1, @"rectangle", nil, 0);
    additem(rotations, @"Auto-Rotate", @selector(rotate:), 2, @"arrow.trianglehead.2.clockwise.rotate.90", nil, 0);
    [device addItem:[NSMenuItem separatorItem]];
    additem(device, @"Volume Up", send, TAG(SDLK_UP, 0), @"speaker.plus", nil, 0);
    additem(device, @"Volume Down", send, TAG(SDLK_DOWN, 0), @"speaker.minus", nil, 0);
    additem(device, @"Power", send, TAG(SDLK_P, 0), @"power", nil, 0);
    [device addItem:[NSMenuItem separatorItem]];
    additem(device, @"Device Screen", @selector(panel:), 0, @"sun.max", nil, 0);
    additem(device, @"Show Touches", @selector(touches:), 0, @"hand.tap", nil, 0);
    NSMenu *lights = submenu(device, @"Brightness", @"sun.max.fill").submenu;
    additem(lights, @"Low", @selector(brightness:), 0, nil, nil, 0);
    additem(lights, @"Mid", @selector(brightness:), 1, nil, nil, 0);
    additem(lights, @"High", @selector(brightness:), 2, nil, nil, 0);
    [device addItem:[NSMenuItem separatorItem]];
    additem(device, @"Take Screenshot", @selector(screenshot:), 0, @"camera", @"s", CMD);
    additem(device, @"Send File…", @selector(sendfile:), 0, @"square.and.arrow.up", @"o", CMD);
    additem(device, @"Force Stop App", @selector(forcestop:), 0, @"xmark.app", nil, 0);
    stopitem = device.itemArray.lastObject;
    [device addItem:[NSMenuItem separatorItem]];
    additem(device, wireless() ? @"Connected over Wi-Fi" : @"Connected over USB", nil, 0,
            wireless() ? @"wifi" : @"cable.connector", nil, 0);
    additem(device, @"Battery", nil, 0, @"battery.75percent", nil, 0);
    batteryitem = device.itemArray.lastObject;
    capitem = submenu(device, @"Charge Limit", @"battery.100percent.bolt");
    capitem.hidden = YES;
    additem(capitem.submenu, @"Off", @selector(chargecap:), 0, nil, nil, 0);
    [capitem.submenu addItem:[NSMenuItem separatorItem]];
    for (NSInteger percent = 60; percent <= 90; percent += 10) {
        additem(capitem.submenu, [NSString stringWithFormat:@"%ld%%", (long)percent],
                @selector(chargecap:), percent, nil, nil, 0);
    }
    additem(device, @"Wi-Fi", @selector(wifi:), 0, @"wifi", nil, 0);
    additem(device, @"Bluetooth", @selector(bluetooth:), 0, @"dot.radiowaves.left.and.right", nil, 0);
    additem(device, @"Airplane Mode", @selector(airplane:), 0, @"airplane", nil, 0);
    [device addItem:[NSMenuItem separatorItem]];
    NSMenu *power = submenu(device, @"Restart", @"restart").submenu;
    for (NSInteger i = 0; i < 3; i++) {
        additem(power, [POWER[i] stringByAppendingString:@"…"], @selector(power:), i, nil, nil, 0);
    }
    device.delegate = target;
    devicemenu = device;
    readstate();

    NSMenu *help = addmenu(bar, @"Help", bar.numberOfItems);
    additem(help, @"scrcpy Help", @selector(help:), 0, nil, @"?", CMD);
    NSApp.helpMenu = help;
}

// SDL3 creates its menus inside Cocoa_RegisterApp, during SDL_Init(), and the
// window later: runs between the two, before SDL builds the window.
void sc_mirror_frame_init(uint16_t sdl_shortcut_mods, const char *device_serial,
                          bool turn_screen_off) {
    shortcutmod = sdl_shortcut_mods & -sdl_shortcut_mods;
    serial = device_serial ? @(device_serial) : nil;
    panellit = !turn_screen_off;
    target = [ScrcpyMenu new];
    hookgeometry();
    if (!contentrect) {
        LOGW("Mirror frame: SDL window classes not found, window left as is");
    }
    buildmenus();
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification,
                                      NSWindowDidChangeOcclusionStateNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *note) { restyle(note.object); }];
    }
}

// Called on the main thread before scrcpy resizes the window for the new
// content; the refit runs after that resize.
void sc_mirror_frame_set_content_size(struct sc_size size) {
    content = size;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = mirror;
        if (window) {
            fitheight(window);
        }
    });
}
