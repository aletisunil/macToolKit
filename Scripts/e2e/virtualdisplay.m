// A second display for the end-to-end tests, made with CoreGraphics' private
// CGVirtualDisplay (the class Chromium's tests and display utilities use). It
// behaves like a real monitor: its own Space, windows, pointer and hit tests.
//
//   virtualdisplay <width> <height>
//
// Places a width x height (points, 1x) display to the right of the main one,
// prints its frame in global coordinates ("x y w h") once it is online, and
// keeps it until the process is terminated or its parent exits.

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

// The display lives as long as this object does.
static CGVirtualDisplay *keepAlive;

static void fail(NSString *message) {
    fprintf(stderr, "virtualdisplay: %s\n", message.UTF8String);
    exit(1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) fail(@"usage: virtualdisplay <width> <height>");
        unsigned int width = (unsigned int)atoi(argv[1]), height = (unsigned int)atoi(argv[2]);
        if (width < 640 || height < 480) fail(@"width and height must be at least 640 x 480");
        if (!NSClassFromString(@"CGVirtualDisplay")) fail(@"CGVirtualDisplay is not available");

        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"macToolKit E2E";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        // About 96 dpi, so macOS doesn't pick a scaled default.
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 96, height * 25.4 / 96);
        descriptor.vendorID = 0xEEEE;
        descriptor.productID = 0xE2E0;
        descriptor.serialNum = 1;
        descriptor.terminationHandler = ^(id a, id b) { exit(0); };

        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display || display.displayID == 0) fail(@"the window server refused the display");
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 0;
        settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                            initWithWidth:width height:height refreshRate:60]];
        if (![display applySettings:settings]) fail(@"applySettings failed");
        keepAlive = display;
        CGDirectDisplayID displayID = display.displayID;

        // Wait for the display to come online, then put it right of the main
        // display, tops aligned.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!CGDisplayIsOnline(displayID) || CGDisplayPixelsWide(displayID) != width) {
            if ([deadline timeIntervalSinceNow] < 0) fail(@"the display never came online");
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        CGRect main = CGDisplayBounds(CGMainDisplayID());
        CGDisplayConfigRef config;
        CGBeginDisplayConfiguration(&config);
        CGConfigureDisplayOrigin(config, displayID, (int32_t)CGRectGetMaxX(main), (int32_t)main.origin.y);
        if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess)
            fail(@"cannot place the display");
        deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (CGDisplayBounds(displayID).origin.x != CGRectGetMaxX(main)) {
            if ([deadline timeIntervalSinceNow] < 0) fail(@"the display never moved into place");
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        // Let the Dock, menu bar and Spaces settle on the new display.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];

        CGRect bounds = CGDisplayBounds(displayID);
        printf("%d %d %d %d\n", (int)bounds.origin.x, (int)bounds.origin.y,
               (int)bounds.size.width, (int)bounds.size.height);
        fflush(stdout);

        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                                        dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ exit(0); });
        dispatch_resume(term);
        // A test run that dies without cleaning up must not leave a display.
        dispatch_source_t parent = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)getppid(),
                                                          DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(parent, ^{ exit(0); });
        dispatch_resume(parent);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
