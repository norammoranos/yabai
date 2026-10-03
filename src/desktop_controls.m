// Local desktop controls. Window/Space mutations always go through yabai IPC.
// Multitouch byte offsets were independently checked against the working
// OmniWM fork's MultitouchGestureFrame.swift (GPL-2.0-only).
#import <dlfcn.h>
#include "desktop_gesture.h"

static NSString *dc_binary;
static dispatch_queue_t dc_queue;
static BOOL dc_enabled, dc_dragging;
static dispatch_source_t dc_termination;
static void dc_multitouch_stop(void);
static void dc_move_cancel(void);
static NSStatusItem *dc_status;
static CFMachPortRef dc_key_tap;
static BOOL dc_caps, dc_caps_used, dc_consumed[128];
static double dc_caps_time;
static void dc_open_overview(void);

static id dc_request(NSArray *args)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.launchPath = dc_binary;
    task.arguments = [@[@"-m"] arrayByAddingObjectsFromArray:args];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try {
        [task launch];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        id result = task.terminationStatus == 0 && data.length
                    ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        [task release];
        return result;
    } @catch (NSException *exception) { (void)exception; [task release]; return nil; }
}

static void dc_command(NSArray *args)
{
    dispatch_async(dc_queue, ^{ @autoreleasepool { dc_request(args); } });
}

static NSNumber *dc_cursor_display(void)
{
    // yabai indices are stable only within a queried snapshot, unlike CG IDs.
    NSArray *displays = dc_request(@[@"query", @"--displays"]);
    CGEventRef event = CGEventCreate(NULL);
    CGPoint point = CGEventGetLocation(event); CFRelease(event);
    for (NSDictionary *display in displays) {
        NSDictionary *f = display[@"frame"];
        if (CGRectContainsPoint(CGRectMake([f[@"x"] doubleValue], [f[@"y"] doubleValue],
                                          [f[@"w"] doubleValue], [f[@"h"] doubleValue]), point)) return display[@"index"];
    }
    return nil;
}

static void dc_space_step(BOOL backward)
{
    dispatch_async(dc_queue, ^{ @autoreleasepool {
        NSNumber *display = dc_cursor_display();
        NSArray *spaces = dc_request(@[@"query", @"--spaces"]);
        NSMutableArray *local = [NSMutableArray array]; NSInteger active = -1;
        for (NSDictionary *space in spaces) {
            if ([space[@"display"] isEqual:display] && ![space[@"is-native-fullscreen"] boolValue]) {
                if ([space[@"is-visible"] boolValue]) active = local.count;
                [local addObject:space];
            }
        }
        if (active < 0 || local.count < 2) return;
        NSInteger target = (active + (backward ? -1 : 1) + local.count) % local.count;
        dc_request(@[@"space", @"--focus", [local[target][@"index"] stringValue]]);
    } });
}

static void dc_space_number(NSInteger number, BOOL move, BOOL send)
{
    dispatch_async(dc_queue, ^{ @autoreleasepool {
        NSArray *spaces = dc_request(@[@"query", @"--spaces"]);
        NSNumber *display=dc_cursor_display();NSMutableArray *local=[NSMutableArray array];
        for(NSDictionary *space in spaces)
            if([space[@"display"] isEqual:display]&&![space[@"is-native-fullscreen"] boolValue])[local addObject:space];
        [local sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"index"] compare:b[@"index"]];}];
        if(number<1||number>(NSInteger)local.count)return;
        // Same local-slot contract as the previous profile: Caps+1 selects
        // the first Space of the cursor display, not a different monitor.
        NSDictionary *target=local[number-1];
        NSString *index = [target[@"index"] stringValue];
        if (move) dc_request(@[@"window", @"--space", index]);
        if (!send) dc_request(@[@"space", @"--focus", index]);
    } });
}

static void dc_launch_action(NSString *name)
{
    dispatch_async(dc_queue, ^{ @autoreleasepool {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/yabai-os-settings/actions.json"];
        NSDictionary *actions = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:NULL];
        NSDictionary *action = actions[name];
        if (![action[@"executable"] isKindOfClass:[NSString class]]) return;
        NSTask *task = [[NSTask alloc] init]; task.launchPath = action[@"executable"];
        task.arguments = action[@"arguments"] ?: @[];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try { [task launch]; } @catch (NSException *exception) { (void)exception; }
        [task release];
    } });
}

// Mission Control owns the overview, wallpapers, snapshots and animation.
// Native four-finger gestures are configured in macOS; we never intercept them.
static void dc_open_overview(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url=[NSURL fileURLWithPath:@"/System/Applications/Mission Control.app"];
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
            configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    });
}

static void dc_restore_caps(void)
{
    NSString *helper=[NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/yabai-desktop"];
    if(![[NSFileManager defaultManager] isExecutableFileAtPath:helper])return;
    NSTask *task=[[NSTask alloc] init];task.launchPath=helper;task.arguments=@[@"restore-caps"];
    task.standardOutput=[NSFileHandle fileHandleWithNullDevice];
    task.standardError=[NSFileHandle fileHandleWithNullDevice];
    @try { [task launch];[task waitUntilExit]; } @catch(NSException *exception) {(void)exception;}
    [task release];
}

@interface YabaiDesktopControls : NSObject
- (void)toggleOverview:(id)sender;
- (void)quitDesktop:(id)sender;
@end
static YabaiDesktopControls *dc_target;
@implementation YabaiDesktopControls
- (void)toggleOverview:(id)sender {(void)sender;dc_open_overview();}
- (void)quitDesktop:(id)sender {
    (void)sender;dc_move_cancel();dc_multitouch_stop();dc_restore_caps();[NSApp terminate:nil];
}
@end

static BOOL dc_key_action(CGKeyCode key, CGEventFlags flags)
{
    BOOL shift=flags&kCGEventFlagMaskShift,option=flags&kCGEventFlagMaskAlternate,control=flags&kCGEventFlagMaskControl;
    static const CGKeyCode digits[]={18,19,20,21,23,22,26,28,25};
    for(int i=0;i<9;i++) if(key==digits[i]) { dc_space_number(i+1,shift,shift&&option);return YES; }
    if(key==48) { dc_space_step(shift);return YES; }
    if(key==31 && control) { dc_open_overview();return YES; }
    if(key==36) { dc_launch_action(shift?@"browser":@"terminal");return YES; }
    if(key==3 && shift) { dc_launch_action(@"finder");return YES; }
    if(key==46 && shift) { dc_launch_action(@"music");return YES; }
    if(key==5 && shift) { dc_launch_action(@"messenger");return YES; }
    if(key==5) {
        if(option) {
            dispatch_async(dc_queue, ^{ @autoreleasepool {
                NSDictionary *window=dc_request(@[@"query",@"--windows",@"--window"]);
                NSString *wid=[window[@"id"] stringValue];
                if(!wid || [window[@"stack-index"] integerValue]<=0)return;
                dc_request(@[@"window",wid,@"--toggle",@"float"]);
                dc_request(@[@"window",wid,@"--toggle",@"float"]);
            } });
        }
        else dc_command(@[@"window",@"--stack",@"next"]);
        return YES;
    }
    if(key==15) { dc_command(@[@"space",@"--rotate",@"90"]);return YES; }
    if(key==37 && shift) { dc_launch_action(@"lock");return YES; }
    if(key==17 && shift) { dc_launch_action(@"theme-next");return YES; }
    if(key==11 && control) { dc_launch_action(@"wallpaper-next");return YES; }
    if(key==40) { dc_launch_action(@"cheatsheet");return YES; }
    if(key==3) { dc_command(@[@"window",@"--toggle",@"zoom-fullscreen"]);return YES; }
    if(key==13) { dc_command(@[@"window",@"--close"]);return YES; }
    if(key==49) { dc_command(@[@"window",@"--toggle",@"float"]);return YES; }
    if(key==11) { dc_command(@[@"space",@"--balance"]);return YES; }
    if(key==33||key==30) { dc_command(@[@"window",@"--focus",key==33?@"stack.prev":@"stack.next"]);return YES; }
    if(key==123||key==124||key==125||key==126) {
        NSString *direction=key==123?@"west":key==124?@"east":key==125?@"south":@"north";
        if(control&&shift) { dc_command(@[@"window",@"--display",direction]);dc_command(@[@"display",@"--focus",direction]); }
        else dc_command(@[control?@"display":@"window",shift?@"--swap":@"--focus",direction]);return YES;
    }
    return NO;
}

static CGEventRef dc_keyboard(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context)
{
    (void)proxy;(void)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput) {
        dc_caps=NO;dc_caps_used=YES; memset(dc_consumed,0,sizeof(dc_consumed)); CGEventTapEnable(dc_key_tap,true);return event;
    }
    if(CGEventGetIntegerValueField(event,kCGEventSourceUserData)==0x59414241) return event;
    CGKeyCode key=(CGKeyCode)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
    if(key==79) { // Caps is remapped to F18 by the owned profile, preserving physical modifiers.
        if(type==kCGEventKeyDown) {
            if(!dc_caps) {dc_caps=YES;dc_caps_used=NO;dc_caps_time=CFAbsoluteTimeGetCurrent();}
        } else if(type==kCGEventKeyUp) {
            if(dc_caps&&!dc_caps_used&&CFAbsoluteTimeGetCurrent()-dc_caps_time<.35) {
                for(int down=1;down>=0;--down) { CGEventRef esc=CGEventCreateKeyboardEvent(NULL,53,down);CGEventSetIntegerValueField(esc,kCGEventSourceUserData,0x59414241);CGEventPost(kCGHIDEventTap,esc);CFRelease(esc); }
            }
            dc_caps=NO;
        }
        return NULL;
    }
    if(type==kCGEventKeyUp&&key<128&&dc_consumed[key]) {dc_consumed[key]=NO;return NULL;}
    if(type==kCGEventKeyDown&&dc_caps) {
        dc_caps_used=YES;
        if(dc_key_action(key,CGEventGetFlags(event))) {if(key<128)dc_consumed[key]=YES;return NULL;}
    }
    return event;
}

typedef int (*dc_mt_callback)(void *,void *,int,double,int,void *);
static CFArrayRef dc_mt_devices;
static void *dc_mt_lib;
static int (*dc_mt_stop)(void *),(*dc_mt_start)(void *,int);
static int (*dc_mt_unregister)(void *,dc_mt_callback),(*dc_mt_register)(void *,dc_mt_callback,void *);
static struct desktop_gesture_state dc_gesture[32];
static CGPoint dc_move_origin;
static float dc_move_x,dc_move_y;
static NSUInteger dc_move_slot;

static void dc_move_event(CGEventType type, CGPoint point)
{
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
    CGEventSetFlags(event,kCGEventFlagMaskAlternate);CGEventSetIntegerValueField(event,kCGEventSourceUserData,0x59414241);
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);
}

static int dc_mt_frame(void *device,void *fingers,int count,double timestamp,int frame,void *context)
{
    (void)device;(void)timestamp;(void)frame;
    float x=0,y=0;int touching=0;
    if(count<0||count>16) return 0;
    for(int i=0;fingers&&i<count;i++) {
        char *p=(char *)fingers+i*96;int state;float px,py;
        memcpy(&state,p+20,4);memcpy(&px,p+32,4);memcpy(&py,p+36,4);
        if(state==4&&isfinite(px)&&isfinite(py)) {x+=px;y+=py;++touching;}
    }
    if(touching) {x/=touching;y/=touching;}
    NSUInteger slot=(NSUInteger)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL option=CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState)&kCGEventFlagMaskAlternate;
        enum desktop_gesture_action action=desktop_gesture_update(&dc_gesture[slot],touching,option,x,y);
        if(action==DESKTOP_GESTURE_MOVE_BEGIN&&!dc_dragging) {
            CGEventRef event=CGEventCreate(NULL);dc_move_origin=CGEventGetLocation(event);CFRelease(event);
            dc_move_x=x;dc_move_y=y;dc_move_slot=slot;dc_dragging=YES;dc_move_event(kCGEventLeftMouseDown,dc_move_origin);
        } else if(action==DESKTOP_GESTURE_MOVE&&dc_dragging&&slot==dc_move_slot) {
            CGPoint point={dc_move_origin.x+(x-dc_move_x)*1800,dc_move_origin.y-(y-dc_move_y)*1100};
            CGWarpMouseCursorPosition(point);dc_move_event(kCGEventLeftMouseDragged,point);
        } else if(action==DESKTOP_GESTURE_MOVE_END&&dc_dragging&&slot==dc_move_slot) {
            CGEventRef event=CGEventCreate(NULL);CGPoint point=CGEventGetLocation(event);CFRelease(event);
            dc_move_event(kCGEventLeftMouseUp,point);dc_dragging=NO;
        }
    });
    return 0;
}

static void dc_move_cancel(void)
{
    if(dc_dragging) {
        CGEventRef event=CGEventCreate(NULL);CGPoint point=CGEventGetLocation(event);CFRelease(event);
        dc_move_event(kCGEventLeftMouseUp,point);dc_dragging=NO;
    }
    memset(dc_gesture,0,sizeof(dc_gesture));dc_caps=NO;
}

static void dc_multitouch_stop(void)
{
    if(dc_mt_devices) {
        for(CFIndex i=0;i<MIN(CFArrayGetCount(dc_mt_devices),32);i++) {
            void *device=(void *)CFArrayGetValueAtIndex(dc_mt_devices,i);
            dc_mt_stop(device);dc_mt_unregister(device,dc_mt_frame);
        }
        CFRelease(dc_mt_devices);dc_mt_devices=NULL;
    }
}

static void dc_multitouch_begin(void)
{
    dc_multitouch_stop();
    if(!dc_mt_lib)dc_mt_lib=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LAZY);
    if(!dc_mt_lib)return;
    CFArrayRef (*create)(void)=dlsym(dc_mt_lib,"MTDeviceCreateList");
    dc_mt_start=dlsym(dc_mt_lib,"MTDeviceStart");dc_mt_stop=dlsym(dc_mt_lib,"MTDeviceStop");
    dc_mt_register=dlsym(dc_mt_lib,"MTRegisterContactFrameCallbackWithRefcon");dc_mt_unregister=dlsym(dc_mt_lib,"MTUnregisterContactFrameCallback");
    if(!create||!dc_mt_start||!dc_mt_stop||!dc_mt_register||!dc_mt_unregister)return;
    dc_mt_devices=create();
    for(CFIndex i=0;dc_mt_devices&&i<MIN(CFArrayGetCount(dc_mt_devices),32);i++) {
        void *device=(void *)CFArrayGetValueAtIndex(dc_mt_devices,i);
        dc_mt_register(device,dc_mt_frame,(void *)(uintptr_t)i);dc_mt_start(device,0);
    }
}

static void desktop_controls_begin(void)
{
    const char *enabled=getenv("YABAI_DESKTOP_CONTROLS");if(!enabled||strcmp(enabled,"1"))return;
    char path[4096];uint32_t size=sizeof(path);if(_NSGetExecutablePath(path,&size))return;
    dc_binary=[[NSString stringWithUTF8String:path] copy];dc_queue=dispatch_queue_create("yabai.desktop-controls",DISPATCH_QUEUE_SERIAL);
    dc_target=[[YabaiDesktopControls alloc] init];
    dc_key_tap=CGEventTapCreate(kCGHIDEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,
                             CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp),dc_keyboard,NULL);
    if(!dc_key_tap) {fprintf(stderr,"yabai: Caps controls event tap unavailable\n");return;}
    CFRunLoopSourceRef source=CFMachPortCreateRunLoopSource(NULL,dc_key_tap,0);
    CFRunLoopAddSource(CFRunLoopGetMain(),source,kCFRunLoopCommonModes);CFRelease(source);
    dc_enabled=YES;dc_multitouch_begin();
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;dc_move_cancel();dc_multitouch_begin();
    }];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;dc_move_cancel();dc_multitouch_stop();
    }];
    signal(SIGTERM,SIG_IGN);
    dc_termination=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(dc_termination, ^{[dc_target quitDesktop:nil];});
    dispatch_resume(dc_termination);
    dc_status=[[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    dc_status.button.title=@"▦";dc_status.button.toolTip=@"yabai — управление окнами";
    NSMenu *menu=[[[NSMenu alloc] initWithTitle:@"yabai"] autorelease];
    NSMenuItem *overview=[[[NSMenuItem alloc] initWithTitle:@"Обзор столов" action:@selector(toggleOverview:) keyEquivalent:@""] autorelease];
    overview.target=dc_target;[menu addItem:overview];
    NSMenuItem *quit=[[[NSMenuItem alloc] initWithTitle:@"Завершить yabai" action:@selector(quitDesktop:) keyEquivalent:@""] autorelease];
    quit.target=dc_target;[menu addItem:quit];dc_status.menu=menu;
    fprintf(stderr,"yabai: desktop controls ready (Caps, native Mission Control, Option+3)\n");
}

static bool desktop_controls_suppress_dock_gesture(CGEventRef event)
{
    return dc_enabled && (dc_dragging || (CGEventGetFlags(event)&kCGEventFlagMaskAlternate));
}

static uint64_t dc_edge_generation;
static uint32_t dc_edge_window;
static int dc_edge_side;
static bool dc_edge_fired;

static void desktop_controls_edge_cancel(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        __atomic_add_fetch(&dc_edge_generation,1,__ATOMIC_RELAXED);dc_edge_window=0;dc_edge_side=0;dc_edge_fired=false;
    });
}

static void desktop_controls_edge_update(uint32_t wid, CGPoint point)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!dc_enabled) return;
        CGDirectDisplayID display=0;uint32_t count=0;
        if(CGGetDisplaysWithPoint(point,1,&display,&count)!=kCGErrorSuccess||!count)return;
        CGRect bounds=CGDisplayBounds(display);
        int side=point.x<=CGRectGetMinX(bounds)+12?-1:point.x>=CGRectGetMaxX(bounds)-12?1:0;
        if(!side) {__atomic_add_fetch(&dc_edge_generation,1,__ATOMIC_RELAXED);dc_edge_side=0;dc_edge_window=0;dc_edge_fired=false;return;}
        if(dc_edge_window==wid&&dc_edge_side==side) return;
        dc_edge_window=wid;dc_edge_side=side;dc_edge_fired=false;
        uint64_t generation=__atomic_add_fetch(&dc_edge_generation,1,__ATOMIC_RELAXED);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(generation!=__atomic_load_n(&dc_edge_generation,__ATOMIC_RELAXED)||dc_edge_fired||(!dc_dragging&&!CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)))return;
            dc_edge_fired=true;
            dispatch_async(dc_queue, ^{ @autoreleasepool {
                NSNumber *cursor=dc_cursor_display();
                NSArray *spaces=dc_request(@[@"query",@"--spaces"]);NSMutableArray *local=[NSMutableArray array];NSInteger active=-1;
                for(NSDictionary *space in spaces) if([space[@"display"] isEqual:cursor]&&![space[@"is-native-fullscreen"] boolValue]) {
                    if([space[@"is-visible"] boolValue])active=local.count;[local addObject:space];
                }
                NSInteger destination=active+side;
                if(active<0||destination<0||destination>=(NSInteger)local.count)return;
                NSString *target=[local[destination][@"index"] stringValue];
                // The IPC queue may have been busy after the dwell timer fired.
                // Recheck cancellation and the button at execution time.
                if(generation!=__atomic_load_n(&dc_edge_generation,__ATOMIC_RELAXED)||!CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft))return;
                dc_request(@[@"window",[NSString stringWithFormat:@"%u",wid],@"--space",target]);
                dc_request(@[@"space",@"--focus",target]);
            } });
        });
    });
}
