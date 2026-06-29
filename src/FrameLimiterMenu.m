#import <Cocoa/Cocoa.h>
#include <signal.h>
#include <errno.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSTimer *timer;
@property (strong) NSMenu *menu;

@property (strong) NSMenuItem *infoItem1;
@property (strong) NSMenuItem *infoItem2;

@property (strong) NSArray *fpsItems;
@property (strong) NSMenuItem *customFpsItem;
@property (strong) NSArray *bgFpsItems;
@property (strong) NSMenuItem *hudItem;
@property (strong) NSMenu *gamesMenu;

@property (assign) BOOL ephemeral;     // launched with --auto by the game wrapper
@property (assign) int  autoGamePid;   // game pid handed over via --gamepid (-1 if none)
@property (assign) int  lastGamePid;   // pid of the most recently observed live game
@property (assign) BOOL sawGame;       // a live game has appeared since launch
@property (assign) int  idleTicks;     // consecutive 1s ticks with no live game
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // The game wrapper launches us with `--auto --gamepid <pid>`; in that mode we self-quit
    // when that game process exits. A manual launch (no --auto) stays open for game setup.
    NSArray *launchArgs = [[NSProcessInfo processInfo] arguments];
    self.ephemeral = [launchArgs containsObject:@"--auto"];
    self.autoGamePid = -1;
    NSUInteger gpi = [launchArgs indexOfObject:@"--gamepid"];
    if (gpi != NSNotFound && gpi + 1 < launchArgs.count) {
        self.autoGamePid = [launchArgs[gpi + 1] intValue];
    }

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"–";
    
    self.menu = [[NSMenu alloc] init];
    self.menu.delegate = self;
    
    self.infoItem1 = [[NSMenuItem alloc] initWithTitle:@"No game running" action:nil keyEquivalent:@""];
    [self.infoItem1 setEnabled:NO];
    [self.menu addItem:self.infoItem1];
    
    self.infoItem2 = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [self.infoItem2 setEnabled:NO];
    [self.infoItem2 setHidden:YES];
    [self.menu addItem:self.infoItem2];
    
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    NSArray *fpsPresets = @[@0, @15, @20, @30, @60, @80];
    NSMutableArray *fpsM = [NSMutableArray array];
    for (NSNumber *n in fpsPresets) {
        NSString *title = n.integerValue == 0 ? @"Off" : n.stringValue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(setFps:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = n;
        [self.menu addItem:item];
        [fpsM addObject:item];
    }
    self.fpsItems = fpsM;
    
    self.customFpsItem = [[NSMenuItem alloc] initWithTitle:@"Custom..." action:@selector(setCustomFps:) keyEquivalent:@""];
    self.customFpsItem.target = self;
    [self.menu addItem:self.customFpsItem];
    
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *bgMenuRoot = [[NSMenuItem alloc] initWithTitle:@"Background cap" action:nil keyEquivalent:@""];
    NSMenu *bgMenu = [[NSMenu alloc] init];
    NSArray *bgPresets = @[@0, @5, @10, @15, @30];
    NSMutableArray *bgM = [NSMutableArray array];
    for (NSNumber *n in bgPresets) {
        NSString *title = n.integerValue == 0 ? @"Off" : n.stringValue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(setBgFps:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = n;
        [bgMenu addItem:item];
        [bgM addObject:item];
    }
    self.bgFpsItems = bgM;
    [bgMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *bgNote = [[NSMenuItem alloc] initWithTitle:@"(applies next launch)" action:nil keyEquivalent:@""];
    [bgNote setEnabled:NO];
    [bgMenu addItem:bgNote];
    
    bgMenuRoot.submenu = bgMenu;
    [self.menu addItem:bgMenuRoot];
    
    self.hudItem = [[NSMenuItem alloc] initWithTitle:@"Metal HUD (applies next launch)" action:@selector(toggleHud:) keyEquivalent:@""];
    self.hudItem.target = self;
    [self.menu addItem:self.hudItem];
    
    NSMenuItem *gamesMenuRoot = [[NSMenuItem alloc] initWithTitle:@"Games" action:nil keyEquivalent:@""];
    self.gamesMenu = [[NSMenu alloc] init];
    self.gamesMenu.delegate = self;
    gamesMenuRoot.submenu = self.gamesMenu;
    [self.menu addItem:gamesMenuRoot];
    
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *logItem = [[NSMenuItem alloc] initWithTitle:@"Open Log" action:@selector(openLog:) keyEquivalent:@""];
    logItem.target = self;
    [self.menu addItem:logItem];
    
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quitApp:) keyEquivalent:@""];
    quitItem.target = self;
    [self.menu addItem:quitItem];
    
    self.statusItem.menu = self.menu;
    
    self.timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self tick:nil];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refreshMenuStates];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.gamesMenu) {
        [self rebuildGamesMenu];
    }
}

// Path to the install-lsenv.sh that drives install/uninstall. Prefer the copy bundled in
// the app (self-contained — works from /Applications); fall back to the repo's scripts/
// for a dev build run out of build/. The script resolves the dylib + wrapper source
// relative to itself, so either location works. nil = neither found.
- (NSString *)installScriptPath {
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"install-lsenv" ofType:@"sh"];
    if (bundled && [[NSFileManager defaultManager] isReadableFileAtPath:bundled]) return bundled;
    NSString *repo = [[[[NSBundle mainBundle] bundlePath]
                       stringByAppendingPathComponent:@"../.."] stringByStandardizingPath];
    NSString *repoScript = [repo stringByAppendingPathComponent:@"scripts/install-lsenv.sh"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:repoScript]) return repoScript;
    return nil;
}

- (void)rebuildGamesMenu {
    [self.gamesMenu removeAllItems];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![self installScriptPath]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Install unavailable — run 'make install-app'" action:nil keyEquivalent:@""];
        [item setEnabled:NO];
        [self.gamesMenu addItem:item];
        return;
    }
    
    NSMutableSet *discoveredPaths = [NSMutableSet set];
    
    NSString *steamBase = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
    NSString *steamApps = [steamBase stringByAppendingPathComponent:@"steamapps"];
    NSMutableArray *libraryDirs = [NSMutableArray array];
    
    if ([fm fileExistsAtPath:steamApps]) {
        [libraryDirs addObject:steamApps];
        NSString *vdfPath = [steamApps stringByAppendingPathComponent:@"libraryfolders.vdf"];
        if ([fm fileExistsAtPath:vdfPath]) {
            NSString *vdf = [NSString stringWithContentsOfFile:vdfPath encoding:NSUTF8StringEncoding error:nil];
            if (vdf) {
                NSArray *lines = [vdf componentsSeparatedByString:@"\n"];
                for (NSString *line in lines) {
                    if ([line containsString:@"\"path\""]) {
                        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\"path\"\\s+\"([^\"]+)\"" options:0 error:nil];
                        NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                        if (match) {
                            NSString *dir = [line substringWithRange:[match rangeAtIndex:1]];
                            [libraryDirs addObject:[dir stringByAppendingPathComponent:@"steamapps"]];
                        }
                    }
                }
            }
        }
    }
    
    for (NSString *lib in libraryDirs) {
        NSString *common = [lib stringByAppendingPathComponent:@"common"];
        NSArray *games = [fm contentsOfDirectoryAtPath:common error:nil];
        for (NSString *game in games) {
            NSString *gameDir = [common stringByAppendingPathComponent:game];
            NSArray *contents = [fm contentsOfDirectoryAtPath:gameDir error:nil];
            for (NSString *item in contents) {
                if ([item.pathExtension isEqualToString:@"app"]) {
                    [discoveredPaths addObject:[[gameDir stringByAppendingPathComponent:item] stringByStandardizingPath]];
                }
            }
        }
    }
    
    NSArray *manualGames = [[NSUserDefaults standardUserDefaults] arrayForKey:@"manualGames"];
    for (NSString *path in manualGames) {
        [discoveredPaths addObject:[path stringByStandardizingPath]];
    }
    
    NSMutableArray *allGames = [NSMutableArray array];
    for (NSString *path in discoveredPaths) {
        if ([fm fileExistsAtPath:path]) {
            [allGames addObject:path];
        }
    }
    
    [allGames sortUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        return [[self displayNameForApp:obj1] localizedCaseInsensitiveCompare:[self displayNameForApp:obj2]];
    }];

    for (NSString *appPath in allGames) {
        NSString *name = [self displayNameForApp:appPath];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(toggleGameInstall:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = appPath;
        if ([self isWrapperInstalledAt:appPath]) {
            item.state = NSControlStateValueOn;
        }
        [self.gamesMenu addItem:item];
    }
    
    [self.gamesMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *addGameItem = [[NSMenuItem alloc] initWithTitle:@"Add game…" action:@selector(addManualGame:) keyEquivalent:@""];
    addGameItem.target = self;
    [self.gamesMenu addItem:addGameItem];
    
    NSMenuItem *rescanItem = [[NSMenuItem alloc] initWithTitle:@"Rescan" action:@selector(rescanGames:) keyEquivalent:@""];
    rescanItem.target = self;
    [self.gamesMenu addItem:rescanItem];
}

// Is the limiter wrapper installed in this bundle? Our wrapper is tiny (tens of KB); a
// real game binary is multi-MB. So: skip anything large outright (cheap, no read), then
// check the small candidates for the lowercase 'framelimiter' token that EVERY wrapper
// version embeds (they all reference the ~/.framelimiter control files). This matches
// install-lsenv.sh's is_wrapper exactly — so older markerless wrappers are recognised
// too (a marker-only check showed installed games as un-installed) — and never pages a
// huge game binary through memory on the main thread.
- (BOOL)isWrapperInstalledAt:(NSString *)appPath {
    @autoreleasepool {
        NSString *plistPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *exeName = plist[@"CFBundleExecutable"];
        if (!exeName) return NO;
        NSString *exePath = [[appPath stringByAppendingPathComponent:@"Contents/MacOS"]
                             stringByAppendingPathComponent:exeName];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:exePath error:nil];
        if (!attrs) return NO;
        unsigned long long sz = [attrs fileSize];
        if (sz == 0 || sz > (2ULL << 20)) return NO;   // > 2 MB ⇒ a real game binary, not our wrapper
        NSData *exeData = [NSData dataWithContentsOfFile:exePath options:NSDataReadingMappedIfSafe error:nil];
        if (!exeData) return NO;
        NSData *needle = [@"framelimiter" dataUsingEncoding:NSASCIIStringEncoding];
        return [exeData rangeOfData:needle options:0 range:NSMakeRange(0, exeData.length)].location != NSNotFound;
    }
}

// Can this bundle actually be injected? The wrapper sets DYLD_INSERT_LIBRARIES, which only
// applies to Mach-O executables, and the installer can't seal a renamed shell script as
// <exe>.real. A Steam launcher shim (CFBundleExecutable = run.sh doing `open steam://run/…`)
// fails both ways: the game is launched by Steam and never inherits our env. Detect by the
// executable's magic bytes — cheap, no subprocess — so we can refuse before corrupting it.
- (BOOL)isInjectableBundleAt:(NSString *)appPath {
    @autoreleasepool {
        NSString *plistPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *exeName = plist[@"CFBundleExecutable"];
        if (!exeName) return NO;
        NSString *exePath = [[appPath stringByAppendingPathComponent:@"Contents/MacOS"]
                             stringByAppendingPathComponent:exeName];
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:exePath];
        if (!fh) return NO;
        NSData *head = [fh readDataOfLength:4];
        [fh closeFile];
        if (head.length < 4) return NO;
        uint32_t magic;
        memcpy(&magic, head.bytes, 4);
        // Mach-O (thin, either endianness) or FAT/universal (either endianness).
        return magic == 0xFEEDFACE || magic == 0xFEEDFACF ||
               magic == 0xCEFAEDFE || magic == 0xCFFAEDFE ||
               magic == 0xCAFEBABE || magic == 0xBEBAFECA;
    }
}

// Human-friendly label for a game bundle. The .app filename is often a generic engine
// stub (Unity ships "mac.app", "Mac.app"), so prefer the bundle's own display/name keys;
// fall back to the parent folder (the Steam installdir, e.g. "Kingdoms Deck") when the
// filename is one of those stubs, and only then to the raw filename.
- (NSString *)displayNameForApp:(NSString *)appPath {
    NSString *plistPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
        NSString *v = plist[key];
        if ([v isKindOfClass:[NSString class]] && v.length > 0) return v;
    }
    NSString *file = [[appPath lastPathComponent] stringByDeletingPathExtension];
    NSArray *stubs = @[@"mac", @"game", @"launcher", @"app"];
    if ([stubs containsObject:[file lowercaseString]]) {
        NSString *parent = [[appPath stringByDeletingLastPathComponent] lastPathComponent];
        if (parent.length > 0) return parent;
    }
    return file;
}

- (void)rescanGames:(id)sender {
    // Menu is rebuilt on open anyway.
}

- (void)addManualGame:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = @"Choose a game's .app bundle";

    if ([panel runModal] != NSModalResponseOK) return;
    NSURL *url = panel.URL;
    if (!url) return;

    // Validate it's really an app bundle rather than restricting the panel by type
    // (allowedFileTypes is deprecated; allowedContentTypes would pull in UniformTypeIdentifiers).
    NSString *path = [url.path stringByStandardizingPath];
    NSString *infoPlist = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:infoPlist]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Not an app bundle";
        alert.informativeText = @"Pick a macOS .app bundle (a folder containing Contents/Info.plist).";
        [alert runModal];
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *manualGames = [[defaults arrayForKey:@"manualGames"] mutableCopy];
    if (!manualGames) manualGames = [NSMutableArray array];
    if (![manualGames containsObject:path]) {
        [manualGames addObject:path];
        [defaults setObject:manualGames forKey:@"manualGames"];
    }
}

- (void)toggleGameInstall:(NSMenuItem *)sender {
    NSString *appPath = sender.representedObject;
    BOOL isInstalled = (sender.state == NSControlStateValueOn);

    NSString *scriptPath = [self installScriptPath];
    if (!scriptPath) return;

    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        NSString *runningPath = app.bundleURL.path;
        if (runningPath && ([runningPath isEqualToString:appPath] ||
                            [runningPath hasPrefix:[appPath stringByAppendingString:@"/"]])) {
            [NSApp activateIgnoringOtherApps:YES];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [NSString stringWithFormat:@"Quit %@ first", [self displayNameForApp:appPath]];
            alert.informativeText = @"The game must be closed before installing or uninstalling the frame limiter.";
            [alert runModal];
            return;
        }
    }
    
    // Refuse to wrap a non-injectable bundle (e.g. a Steam launcher shim). Filtering
    // discovery alone wouldn't catch manually-added shims, so gate at the click.
    if (!isInstalled && ![self isInjectableBundleAt:appPath]) {
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Can't inject into this app";
        alert.informativeText = [NSString stringWithFormat:
            @"“%@” isn't a Mach-O game binary — it looks like a Steam launcher that hands "
            @"off to Steam, so there's nothing to inject here. Add the real game .app "
            @"instead (usually under ~/Library/Application Support/Steam/steamapps/common/).",
            [self displayNameForApp:appPath]];
        [alert runModal];
        return;
    }

    NSString *fpsStr = [self readStringFromFile:@".framelimiter.fps"];
    if (!fpsStr || fpsStr.length == 0 || [fpsStr integerValue] == 0) {
        fpsStr = @"80";
    } else {
        fpsStr = [NSString stringWithFormat:@"%ld", (long)[fpsStr integerValue]];
    }

    NSMutableArray *args = [NSMutableArray array];
    [args addObject:scriptPath];
    if (isInstalled) {
        [args addObject:@"uninstall"];
        [args addObject:appPath];
    } else {
        [args addObject:@"install"];
        [args addObject:appPath];
        [args addObject:fpsStr];
    }
    
    sender.title = isInstalled ? @"Uninstalling…" : @"Installing…";
    sender.enabled = NO;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/bin/bash";
        task.arguments = args;
        
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;
        
        NSData *outputData = nil;
        @try {
            [task launch];
            outputData = [[pipe fileHandleForReading] readDataToEndOfFile];
            [task waitUntilExit];
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Error launching script";
                alert.informativeText = e.reason;
                [alert runModal];
                [self rebuildGamesMenu];
            });
            return;
        }
        
        NSString *outputString = @"";
        if (outputData) {
            outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        }
        
        int status = task.terminationStatus;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self rebuildGamesMenu];
            if (status != 0) {
                [NSApp activateIgnoringOtherApps:YES];
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Operation failed";
                alert.informativeText = outputString.length > 0 ? outputString : @"Unknown error";
                [alert runModal];
            }
        });
    });
}

- (NSString *)pathForFile:(NSString *)filename {
    return [NSHomeDirectory() stringByAppendingPathComponent:filename];
}

- (void)writeString:(NSString *)str toFile:(NSString *)filename {
    NSString *path = [self pathForFile:filename];
    [str writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)readStringFromFile:(NSString *)filename {
    NSString *path = [self pathForFile:filename];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

- (void)setFpsValue:(NSInteger)val {
    [self writeString:[NSString stringWithFormat:@"%ld\n", (long)val] toFile:@".framelimiter.fps"];
    if (val > 0) {
        [self writeString:[NSString stringWithFormat:@"%ld\n", (long)val] toFile:@".framelimiter.fps.last"];
    }
    [self refreshMenuStates];
}

- (void)setFps:(NSMenuItem *)sender {
    NSInteger val = [sender.representedObject integerValue];
    [self setFpsValue:val];
}

- (void)setCustomFps:(NSMenuItem *)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Set Custom Frame Cap";
    alert.informativeText = @"Enter an integer between 0 and 1000 (0 to disable):";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    alert.accessoryView = input;
    
    NSInteger button = [alert runModal];
    if (button == NSAlertFirstButtonReturn) {
        NSInteger val = [input.stringValue integerValue];
        if (val < 0) val = 0;
        if (val > 1000) val = 1000;
        [self setFpsValue:val];
    }
}

- (void)setBgFps:(NSMenuItem *)sender {
    NSInteger val = [sender.representedObject integerValue];
    [self writeString:[NSString stringWithFormat:@"%ld\n", (long)val] toFile:@".framelimiter.bgfps"];
    [self refreshMenuStates];
}

- (void)toggleHud:(NSMenuItem *)sender {
    NSString *hudStr = [self readStringFromFile:@".framelimiter.hud"];
    NSInteger hudVal = 1;
    if (hudStr && [[hudStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0) {
        hudVal = [hudStr integerValue];
    }
    NSInteger newVal = hudVal == 0 ? 1 : 0;
    [self writeString:[NSString stringWithFormat:@"%ld\n", (long)newVal] toFile:@".framelimiter.hud"];
    [self refreshMenuStates];
}

- (void)openLog:(id)sender {
    NSString *path = [self pathForFile:@".framelimiter.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)quitApp:(id)sender {
    [NSApp terminate:nil];
}

- (void)refreshMenuStates {
    NSString *fpsStr = [self readStringFromFile:@".framelimiter.fps"];
    NSInteger currentFps = 0;
    if (fpsStr && fpsStr.length > 0) {
        currentFps = [fpsStr integerValue];
    }
    
    for (NSMenuItem *item in self.fpsItems) {
        NSInteger itemVal = [item.representedObject integerValue];
        item.state = (itemVal == currentFps) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.customFpsItem.state = NSControlStateValueOff;
    BOOL isPreset = NO;
    for (NSNumber *n in @[@0, @15, @20, @30, @60, @80]) {
        if (n.integerValue == currentFps) isPreset = YES;
    }
    if (!isPreset) {
        self.customFpsItem.state = NSControlStateValueOn;
        self.customFpsItem.title = [NSString stringWithFormat:@"Custom (%ld)...", (long)currentFps];
    } else {
        self.customFpsItem.title = @"Custom...";
    }
    
    NSString *bgFpsStr = [self readStringFromFile:@".framelimiter.bgfps"];
    NSInteger currentBgFps = 10;
    if (bgFpsStr && bgFpsStr.length > 0) {
        currentBgFps = [bgFpsStr integerValue];
    }
    
    for (NSMenuItem *item in self.bgFpsItems) {
        NSInteger itemVal = [item.representedObject integerValue];
        item.state = (itemVal == currentBgFps) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    
    NSString *hudStr = [self readStringFromFile:@".framelimiter.hud"];
    NSInteger hudVal = 1;
    if (hudStr && [[hudStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0) {
        hudVal = [hudStr integerValue];
    }
    self.hudItem.state = (hudVal == 1) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)tick:(NSTimer *)t {
    NSString *statusStr = [self readStringFromFile:@".framelimiter.status"];
    BOOL isLive = NO;
    
    int pid = 0, target = 0, background = 0, bg_fps = 0;
    float measured_fps = 0.0f;
    long ts = 0;
    
    if (statusStr && statusStr.length > 0) {
        NSArray *lines = [statusStr componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            NSArray *parts = [line componentsSeparatedByString:@"="];
            if (parts.count == 2) {
                NSString *k = parts[0];
                NSString *v = parts[1];
                if ([k isEqualToString:@"pid"]) pid = [v intValue];
                else if ([k isEqualToString:@"target"]) target = [v intValue];
                else if ([k isEqualToString:@"measured_fps"]) measured_fps = [v floatValue];
                else if ([k isEqualToString:@"background"]) background = [v intValue];
                else if ([k isEqualToString:@"bg_fps"]) bg_fps = [v intValue];
                else if ([k isEqualToString:@"ts"]) ts = (long)[v longLongValue];
            }
        }
        
        long now = (long)[[NSDate date] timeIntervalSince1970];
        if (now - ts <= 3) {
            isLive = YES;
        }
    }
    
    if (isLive) {
        self.statusItem.button.title = [NSString stringWithFormat:@"%.0f", measured_fps];
        self.infoItem1.title = [NSString stringWithFormat:@"Capping %.1f / %d fps  (pid %d)", measured_fps, target, pid];
        if (background == 1) {
            self.infoItem2.title = [NSString stringWithFormat:@"Backgrounded -> %d fps", bg_fps];
            self.infoItem2.hidden = NO;
        } else {
            self.infoItem2.hidden = YES;
        }
    } else {
        self.statusItem.button.title = @"–";
        self.infoItem1.title = @"No game running";
        self.infoItem2.hidden = YES;
    }

    [self refreshMenuStates];

    // Ephemeral mode: quit once the game has actually exited. We track process liveness
    // (kill(pid,0) == ESRCH), NOT heartbeat freshness — many games stop rendering while
    // backgrounded, and a slow first frame means no heartbeat during load either.
    if (self.ephemeral) {
        if (self.autoGamePid > 0) {
            // Authoritative: the wrapper handed us the game's pid, so wait exactly as long
            // as that process lives — load time and render activity are irrelevant.
            if (kill(self.autoGamePid, 0) != 0 && errno == ESRCH) {
                [NSApp terminate:nil];
            }
        } else if (isLive) {
            // Fallback (no --gamepid): learn the pid from the heartbeat.
            self.sawGame = YES;
            self.lastGamePid = pid;
            self.idleTicks = 0;
        } else {
            self.idleTicks++;
            BOOL gone = (self.lastGamePid > 0) &&
                        (kill(self.lastGamePid, 0) != 0 && errno == ESRCH);
            if (self.sawGame && gone) {
                [NSApp terminate:nil];
            } else if (!self.sawGame && self.idleTicks > 30) {
                [NSApp terminate:nil];   // launched --auto but no game ever appeared
            }
        }
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
