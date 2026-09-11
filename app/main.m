// Session HUD: macOS menubar app. Thin client over the Bun server at 127.0.0.1:4243.
// AppKit in Objective-C so it builds with Command Line Tools alone (the CLT Swift compiler and SDK are mismatched on this machine).
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

static NSString *const kServer = @"http://127.0.0.1:4243";
static NSString *const kServerDir = @"~/Development/session-hud";
static const CGFloat kRowHeight = 100;
static const CGFloat kWidth = 500;

// ---------- helpers ----------
static NSString *S(id v) { return [v isKindOfClass:NSString.class] ? v : @""; } // JSON null arrives as NSNull
static NSString *relTime(id isoV) {
    NSString *iso = S(isoV);
    if (!iso.length) return @"";
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d = [f dateFromString:iso];
    if (!d) { f.formatOptions = NSISO8601DateFormatWithInternetDateTime; d = [f dateFromString:iso]; }
    if (!d) return @"";
    NSTimeInterval s = -[d timeIntervalSinceNow];
    if (s < 60) return @"now";
    if (s < 3600) return [NSString stringWithFormat:@"%dm", (int)(s / 60)];
    if (s < 86400) return [NSString stringWithFormat:@"%dh", (int)(s / 3600)];
    if (s < 86400 * 14) return [NSString stringWithFormat:@"%dd", (int)(s / 86400)];
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"MMM d";
    return [df stringFromDate:d];
}
static NSColor *stateColor(NSString *st) {
    if ([st isEqualToString:@"needs_input"]) return NSColor.systemYellowColor;
    if ([st isEqualToString:@"working"]) return NSColor.systemGreenColor;
    if ([st isEqualToString:@"idle"]) return NSColor.systemBlueColor;
    if ([st isEqualToString:@"bg_done"]) return NSColor.systemTealColor;
    if ([st isEqualToString:@"bg_failed"]) return NSColor.systemRedColor;
    return NSColor.tertiaryLabelColor;
}
static NSString *stateLabel(NSString *st) {
    if ([st isEqualToString:@"needs_input"]) return @"needs input";
    if ([st isEqualToString:@"working"]) return @"working";
    if ([st isEqualToString:@"idle"]) return @"idle, open";
    if ([st isEqualToString:@"bg_done"]) return @"background done";
    if ([st isEqualToString:@"bg_failed"]) return @"background failed";
    return @"ended";
}
static int stateRank(NSString *st) {
    if ([st isEqualToString:@"needs_input"]) return 0;
    if ([st isEqualToString:@"working"]) return 1;
    if ([st isEqualToString:@"idle"]) return 2;
    return 3;
}
static NSTextField *label(CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:@""];
    t.font = [NSFont systemFontOfSize:size weight:w]; t.textColor = c; t.lineBreakMode = NSLineBreakByTruncatingTail;
    t.maximumNumberOfLines = 1; t.cell.truncatesLastVisibleLine = YES;
    return t;
}

// ---------- menubar robot icon (vector template image; tinted via contentTintColor) ----------
static NSImage *robotIcon(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 17) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor setFill];
        // antenna
        NSBezierPath *ant = [NSBezierPath bezierPath]; ant.lineWidth = 1.4; [ant moveToPoint:NSMakePoint(9, 12.6)]; [ant lineToPoint:NSMakePoint(9, 14.6)]; [NSColor.blackColor setStroke]; [ant stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(7.7, 14.2, 2.6, 2.6)] fill];
        // ears
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.6, 5.2, 2.2, 4.4) xRadius:0.8 yRadius:0.8] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(15.2, 5.2, 2.2, 4.4) xRadius:0.8 yRadius:0.8] fill];
        // head
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.4, 1.4, 13.2, 11.4) xRadius:3.2 yRadius:3.2] fill];
        // cut-outs: eyes and mouth grille (transparent so the menubar shows through)
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationDestinationOut];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4.9, 6.6, 3.0, 3.4) xRadius:1.1 yRadius:1.1] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(10.1, 6.6, 3.0, 3.4) xRadius:1.1 yRadius:1.1] fill];
        for (int i = 0; i < 3; i++) [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5.2 + i * 2.7, 3.2, 2.1, 1.7) xRadius:0.5 yRadius:0.5] fill];
        return YES;
    }];
    img.template = YES;
    return img;
}

// ---------- terminal launching ----------
@interface Launcher : NSObject
+ (void)resume:(NSDictionary *)row;
@end
@implementation Launcher
+ (NSString *)shellQuote:(NSString *)s { return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }
+ (void)resume:(NSDictionary *)row {
    NSDictionary *r = [row[@"resume"] isKindOfClass:NSDictionary.class] ? row[@"resume"] : @{}; NSString *cmd = S(r[@"command"]); if (!cmd.length) return; NSString *cwd = S(r[@"cwd"]).length ? S(r[@"cwd"]) : NSHomeDirectory();
    NSString *term = [[NSUserDefaults standardUserDefaults] stringForKey:@"terminal"] ?: @"warp";
    NSString *full = [NSString stringWithFormat:@"cd %@ && %@", [self shellQuote:cwd], cmd];
    if ([term isEqualToString:@"warp"]) {
        // Warp launch configuration: written per resume, opened via warp://launch/<name>.
        NSString *dir = [@"~/.warp/launch_configurations" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *yamlCmd = [full stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        yamlCmd = [yamlCmd stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSString *yaml = [NSString stringWithFormat:@"name: session-hud-resume\nwindows:\n  - tabs:\n      - title: \"%@\"\n        layout:\n          cwd: \"%@\"\n          commands:\n            - exec: \"%@\"\n",
                          [[row[@"title"] description] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"], cwd, yamlCmd];
        [yaml writeToFile:[dir stringByAppendingPathComponent:@"session-hud-resume.yaml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"warp://launch/session-hud-resume"]];
        return;
    }
    // Terminal.app via AppleScript (asks once for Automation permission).
    NSString *esc = [[full stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *src = [NSString stringWithFormat:@"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell", esc];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
    if (err) NSLog(@"Terminal launch failed: %@", err);
}
@end

// ---------- row view ----------
@interface RowView : NSTableCellView
@property NSTextField *dot, *title, *about, *leftOff, *meta, *agents;
@property NSButton *resumeBtn, *btnCopy;
@property NSDictionary *row;
@end
@implementation RowView
- (instancetype)initWithFrame:(NSRect)fr {
    if ((self = [super initWithFrame:fr])) {
        _dot = label(11, NSFontWeightBold, NSColor.labelColor); _dot.stringValue = @"●";
        _title = label(13, NSFontWeightSemibold, NSColor.labelColor);
        _about = label(11.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
        _leftOff = label(11.5, NSFontWeightRegular, NSColor.labelColor); _leftOff.maximumNumberOfLines = 2; _leftOff.lineBreakMode = NSLineBreakByWordWrapping;
        _meta = label(10.5, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        _agents = label(10.5, NSFontWeightMedium, NSColor.systemOrangeColor); _agents.alignment = NSTextAlignmentRight;
        _resumeBtn = [NSButton buttonWithTitle:@"Resume" target:self action:@selector(resume:)]; _resumeBtn.bezelStyle = NSBezelStyleRounded; _resumeBtn.controlSize = NSControlSizeSmall; _resumeBtn.font = [NSFont systemFontOfSize:11];
        _btnCopy = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(doCopy:)]; _btnCopy.bezelStyle = NSBezelStyleRounded; _btnCopy.controlSize = NSControlSizeSmall; _btnCopy.font = [NSFont systemFontOfSize:11];
        for (NSView *v in @[_dot, _title, _about, _leftOff, _meta, _agents, _resumeBtn, _btnCopy]) [self addSubview:v];
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, x = 12, right = W - 12;
    [_btnCopy sizeToFit]; [_resumeBtn sizeToFit];
    _btnCopy.frame = NSMakeRect(right - _btnCopy.frame.size.width, H - 30, _btnCopy.frame.size.width, 22);
    _resumeBtn.frame = NSMakeRect(_btnCopy.frame.origin.x - 4 - _resumeBtn.frame.size.width, H - 30, _resumeBtn.frame.size.width, 22);
    _dot.frame = NSMakeRect(x, H - 27, 14, 16);
    CGFloat titleRight = _resumeBtn.frame.origin.x - 8;
    _title.frame = NSMakeRect(x + 16, H - 28, titleRight - (x + 16), 18);
    _about.frame = NSMakeRect(x + 16, H - 45, right - (x + 16), 16);
    _leftOff.frame = NSMakeRect(x + 16, H - 79, right - (x + 16), 32);
    CGFloat aw = _agents.stringValue.length ? 190 : 0;
    _agents.frame = NSMakeRect(right - aw, 6, aw, 14);
    _meta.frame = NSMakeRect(x + 16, 6, right - aw - (x + 16) - 6, 14);
}
- (void)setRow:(NSDictionary *)row {
    _row = row;
    NSString *st = S(row[@"state"]);
    _dot.textColor = stateColor(st);
    _title.stringValue = S(row[@"title"]).length ? S(row[@"title"]) : @"(untitled)";
    NSString *lo = S(row[@"leftOff"]), *ab = S(row[@"about"]), *lp = S(row[@"lastPrompt"]);
    _about.stringValue = ab;
    if (lo.length) { _leftOff.stringValue = [@"Left off: " stringByAppendingString:lo]; _leftOff.textColor = NSColor.labelColor; }
    else { _leftOff.stringValue = lp.length ? [@"Last prompt: " stringByAppendingString:lp] : @""; _leftOff.textColor = NSColor.tertiaryLabelColor; }
    NSString *ni = [row[@"needsInput"] isKindOfClass:NSString.class] ? row[@"needsInput"] : nil;
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:stateLabel(st), relTime(row[@"lastActivityAt"]), nil];
    if ([row[@"project"] isKindOfClass:NSString.class]) [parts addObject:row[@"project"]];
    [parts addObject:[NSString stringWithFormat:@"%@ turns", [row[@"turns"] isKindOfClass:NSNumber.class] ? row[@"turns"] : @0]];
    if ([row[@"automated"] boolValue]) [parts addObject:@"automated"];
    if (ni) [parts addObject:ni];
    _meta.stringValue = [parts componentsJoinedByString:@"  ·  "];
    NSInteger running = [row[@"runningAgents"] integerValue]; NSArray *ag = row[@"agents"];
    if (running > 0) {
        NSDictionary *first = nil; for (NSDictionary *a in ag) if ([a[@"status"] isEqualToString:@"running"]) { first = a; break; }
        NSString *d = S(first[@"description"]).length ? S(first[@"description"]) : S(first[@"type"]);
        _agents.stringValue = [NSString stringWithFormat:@"⟳ %ld agent%@: %@", (long)running, running == 1 ? @"" : @"s", d ?: @""];
        _agents.textColor = NSColor.systemOrangeColor;
    } else if (ag.count) { _agents.stringValue = [NSString stringWithFormat:@"%lu agents done", (unsigned long)ag.count]; _agents.textColor = NSColor.tertiaryLabelColor; }
    else _agents.stringValue = @"";
    BOOL alive = [row[@"alive"] boolValue];
    _resumeBtn.title = alive && [row[@"live"][@"kind"] isEqualToString:@"interactive"] ? @"Open" : @"Resume";
    _resumeBtn.toolTip = row[@"resume"][@"command"];
    _btnCopy.toolTip = [NSString stringWithFormat:@"Copy: %@", row[@"resume"][@"command"]];
    [self setNeedsLayout:YES];
}
- (void)resume:(id)s { [Launcher resume:_row]; [NSApp sendAction:@selector(closePopover:) to:nil from:self]; }
- (void)doCopy:(id)s {
    NSString *cmd = S([_row[@"resume"] isKindOfClass:NSDictionary.class] ? _row[@"resume"][@"command"] : nil); if (!cmd.length) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard; [pb clearContents]; [pb setString:cmd forType:NSPasteboardTypeString];
    _btnCopy.title = @"Copied"; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ self.btnCopy.title = @"Copy"; [self setNeedsLayout:YES]; });
}
@end

// ---------- table with keys ----------
@interface HUDTable : NSTableView @end
@implementation HUDTable
- (void)cancelOperation:(id)s { [NSApp sendAction:@selector(closePopover:) to:nil from:self]; }
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if ([c isEqualToString:@"\r"] || [c isEqualToString:@"c"]) {
        NSInteger r = self.selectedRow; if (r < 0) return;
        RowView *v = [self viewAtColumn:0 row:r makeIfNecessary:NO];
        if ([c isEqualToString:@"\r"]) [v resume:nil]; else [v doCopy:nil];
        return;
    }
    if ([c isEqualToString:@"j"]) { [self selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(self.selectedRow + 1, self.numberOfRows - 1)] byExtendingSelection:NO]; [self scrollRowToVisible:self.selectedRow]; return; }
    if ([c isEqualToString:@"k"]) { [self selectRowIndexes:[NSIndexSet indexSetWithIndex:MAX(self.selectedRow - 1, 0)] byExtendingSelection:NO]; [self scrollRowToVisible:self.selectedRow]; return; }
    [super keyDown:e];
}
@end

// ---------- view controller ----------
@interface HUDController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property NSArray *all, *rows; @property (nonatomic) NSDictionary *payload;
@property HUDTable *table; @property NSTextField *header, *status; @property NSSegmentedControl *filter; @property NSButton *autoToggle, *detachBtn;
@end
@implementation HUDController
- (void)loadView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 600)];
    _header = label(12, NSFontWeightSemibold, NSColor.labelColor); _header.frame = NSMakeRect(14, 600 - 30, 220, 18); _header.autoresizingMask = NSViewMinYMargin;
    _filter = [NSSegmentedControl segmentedControlWithLabels:@[@"Active", @"Week", @"All"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(refilter:)];
    _filter.selectedSegment = 0; _filter.controlSize = NSControlSizeSmall; _filter.font = [NSFont systemFontOfSize:11]; [_filter sizeToFit];
    _filter.frame = NSMakeRect(kWidth - 14 - _filter.frame.size.width, 600 - 32, _filter.frame.size.width, 22); _filter.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    _autoToggle = [NSButton checkboxWithTitle:@"automated" target:self action:@selector(refilter:)]; _autoToggle.controlSize = NSControlSizeSmall; _autoToggle.font = [NSFont systemFontOfSize:10.5]; [_autoToggle sizeToFit];
    _autoToggle.frame = NSMakeRect(_filter.frame.origin.x - 10 - _autoToggle.frame.size.width, 600 - 30, _autoToggle.frame.size.width, 18); _autoToggle.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    _detachBtn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"pip.exit" accessibilityDescription:@"Detach"] target:nil action:@selector(toggleDetach:)];
    _detachBtn.bezelStyle = NSBezelStyleTexturedRounded; _detachBtn.bordered = NO; _detachBtn.toolTip = @"Detach to a floating panel (or drag the popover away). Close the panel to reattach."; _detachBtn.controlSize = NSControlSizeSmall;
    _detachBtn.frame = NSMakeRect(_autoToggle.frame.origin.x - 8 - 22, 600 - 32, 22, 22); _detachBtn.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 26, kWidth, 600 - 26 - 40)]; sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; sv.hasVerticalScroller = YES; sv.drawsBackground = NO;
    _table = [[HUDTable alloc] initWithFrame:sv.bounds]; _table.headerView = nil; _table.rowHeight = kRowHeight; _table.intercellSpacing = NSMakeSize(0, 1);
    _table.backgroundColor = NSColor.clearColor; _table.usesAlternatingRowBackgroundColors = NO; _table.style = NSTableViewStyleFullWidth; _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"]; col.width = kWidth - 20; [_table addTableColumn:col];
    _table.dataSource = self; _table.delegate = self; _table.doubleAction = @selector(dbl:); _table.target = self;
    sv.documentView = _table;
    _status = label(10.5, NSFontWeightRegular, NSColor.tertiaryLabelColor); _status.frame = NSMakeRect(14, 6, kWidth - 28, 14); _status.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable;
    for (NSView *s in @[_header, _filter, _autoToggle, _detachBtn, sv, _status]) [v addSubview:s];
    self.view = v;
}
- (void)dbl:(id)s { NSInteger r = _table.clickedRow; if (r >= 0) [(RowView *)[_table viewAtColumn:0 row:r makeIfNecessary:NO] resume:nil]; }
- (void)refilter:(id)s { [self apply]; }
- (void)setPayload:(NSDictionary *)p {
    _payload = p; _all = p[@"sessions"] ?: @[];
    NSDictionary *c = p[@"counts"];
    NSMutableArray *bits = [NSMutableArray array];
    if ([c[@"needsInput"] integerValue]) [bits addObject:[NSString stringWithFormat:@"%@ need%@ input", c[@"needsInput"], [c[@"needsInput"] integerValue] == 1 ? @"s" : @""]];
    if ([c[@"working"] integerValue]) [bits addObject:[NSString stringWithFormat:@"%@ working", c[@"working"]]];
    [bits addObject:[NSString stringWithFormat:@"%@ open", c[@"alive"]]];
    _header.stringValue = [bits componentsJoinedByString:@"  ·  "];
    NSInteger pend = [c[@"summariesPending"] integerValue];
    _status.stringValue = [NSString stringWithFormat:@"%@ sessions indexed%@  ·  updated %@  ·  ⏎ resume  c copy  j/k move", c[@"total"], pend ? [NSString stringWithFormat:@", %ld titles pending", (long)pend] : @"", relTime(p[@"generatedAt"])];
    [self apply];
}
- (void)apply {
    NSInteger seg = _filter.selectedSegment; BOOL showAuto = _autoToggle.state == NSControlStateValueOn;
    NSDate *cut = [NSDate dateWithTimeIntervalSinceNow:-(seg == 0 ? 86400 : 7 * 86400)];
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new]; f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in _all) {
        if (!showAuto && [r[@"automated"] boolValue]) continue;
        if (seg < 2 && ![r[@"alive"] boolValue]) {
            NSString *iso = S(r[@"lastActivityAt"]); NSDate *d = iso.length ? [f dateFromString:iso] : nil;
            if (!d || [d compare:cut] == NSOrderedAscending) continue;
        }
        [out addObject:r];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int ra = stateRank(S(a[@"state"])), rb = stateRank(S(b[@"state"]));
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        return [S(b[@"lastActivityAt"]) compare:S(a[@"lastActivityAt"])];
    }];
    NSString *selId = _table.selectedRow >= 0 && _table.selectedRow < (NSInteger)_rows.count ? S(_rows[_table.selectedRow][@"id"]) : nil;
    _rows = out; [_table reloadData];
    if (selId.length) { NSUInteger i = [_rows indexOfObjectPassingTest:^BOOL(NSDictionary *r, NSUInteger idx, BOOL *stop) { return [S(r[@"id"]) isEqualToString:selId]; }]; if (i != NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO]; }
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return _rows.count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    RowView *v = [t makeViewWithIdentifier:@"row" owner:self];
    if (!v) { v = [[RowView alloc] initWithFrame:NSMakeRect(0, 0, kWidth - 20, kRowHeight)]; v.identifier = @"row"; }
    v.row = _rows[r]; return v;
}
@end

// ---------- app delegate ----------
@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate>
@property NSStatusItem *item; @property NSPopover *popover; @property HUDController *hud; @property NSTimer *timer; @property NSDate *lastServerStart; @property BOOL offline;
@property NSPanel *panel; @property EventHotKeyRef hotKeyRef;
- (void)hotkeyPressed;
@end

static OSStatus hotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    NSLog(@"hotkey pressed");
    dispatch_async(dispatch_get_main_queue(), ^{ [(__bridge AppDelegate *)userData hotkeyPressed]; });
    return noErr;
}

@implementation AppDelegate
// ---- global hotkey (Carbon; works without Accessibility permission). Default ⌃⌥H; override with
//      defaults write com.mikecarey.SessionHUD hotkeyKeyCode -int <kVK code>  and  hotkeyModifiers -int <controlKey|optionKey|cmdKey|shiftKey bits>
- (void)registerHotkey {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    UInt32 code = [d objectForKey:@"hotkeyKeyCode"] ? (UInt32)[d integerForKey:@"hotkeyKeyCode"] : kVK_ANSI_H;
    UInt32 mods = [d objectForKey:@"hotkeyModifiers"] ? (UInt32)[d integerForKey:@"hotkeyModifiers"] : (controlKey | optionKey);
    static BOOL installed = NO;
    if (!installed) { EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed }; InstallApplicationEventHandler(&hotKeyHandler, 1, &spec, (__bridge void *)self, NULL); installed = YES; }
    EventHotKeyID hid = { 'SHUD', 1 };
    OSStatus st = RegisterEventHotKey(code, mods, hid, GetApplicationEventTarget(), 0, &_hotKeyRef);
    NSLog(@"hotkey register keyCode=%u mods=%u status=%d", code, mods, (int)st);
    if (st != noErr) { // eventHotKeyExistsErr (-9878): a previous instance may still hold it; retry
        static int attempts = 0;
        if (++attempts < 6) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self registerHotkey]; });
    }
}
- (NSString *)hotkeyLabel {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    UInt32 mods = [d objectForKey:@"hotkeyModifiers"] ? (UInt32)[d integerForKey:@"hotkeyModifiers"] : (controlKey | optionKey);
    UInt32 code = [d objectForKey:@"hotkeyKeyCode"] ? (UInt32)[d integerForKey:@"hotkeyKeyCode"] : kVK_ANSI_H;
    NSMutableString *l = [NSMutableString string];
    if (mods & controlKey) [l appendString:@"⌃"]; if (mods & optionKey) [l appendString:@"⌥"]; if (mods & shiftKey) [l appendString:@"⇧"]; if (mods & cmdKey) [l appendString:@"⌘"];
    [l appendString:code == kVK_ANSI_H ? @"H" : [NSString stringWithFormat:@"key %u", code]];
    return l;
}
- (void)hotkeyPressed {
    if (_panel) { if (_panel.isVisible && _panel.isKeyWindow) [_panel orderOut:nil]; else [self showPanel]; return; }
    [self toggle:nil];
}
// ---- floating panel
- (void)showPanel {
    [_panel makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [_panel makeFirstResponder:_hud.table];
}
- (NSPanel *)makePanel {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    p.title = @"Session HUD"; p.level = NSFloatingWindowLevel; p.hidesOnDeactivate = NO; p.floatingPanel = YES; p.becomesKeyOnlyIfNeeded = NO;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    p.minSize = NSMakeSize(380, 240); p.delegate = self; p.releasedWhenClosed = NO;
    p.titlebarAppearsTransparent = YES; p.movableByWindowBackground = NO;
    [p setFrameAutosaveName:@"SessionHUDPanel"];
    return p;
}
- (void)toggleDetach:(id)s {
    if (_panel) { [_panel close]; return; }
    [_popover close];
    _panel = [self makePanel];
    _popover.contentViewController = nil;
    _panel.contentViewController = _hud;
    if (![_panel setFrameUsingName:@"SessionHUDPanel"]) {
        NSRect sf = (_item.button.window.screen ?: NSScreen.mainScreen).visibleFrame;
        [_panel setFrameTopLeftPoint:NSMakePoint(NSMaxX(sf) - kWidth - 12, NSMaxY(sf) - 8)];
    }
    _hud.detachBtn.image = [NSImage imageWithSystemSymbolName:@"pip.enter" accessibilityDescription:@"Reattach"];
    [self showPanel];
}
// drag the popover off the menubar to detach it (native NSPopover behaviour)
- (BOOL)popoverShouldDetach:(NSPopover *)popover { return YES; }
// AppKit does not move the popover's content into a delegate-supplied window; we move the HUD view over once the popover has closed.
- (NSWindow *)detachableWindowForPopover:(NSPopover *)popover {
    _panel = [self makePanel];
    _hud.detachBtn.image = [NSImage imageWithSystemSymbolName:@"pip.enter" accessibilityDescription:@"Reattach"];
    return _panel;
}
- (void)popoverDidClose:(NSNotification *)n {
    if (_panel && _panel.contentViewController == nil) {
        NSRect f = _panel.frame;
        _popover.contentViewController = nil;
        _panel.contentViewController = _hud;
        [_panel setFrame:f display:YES];
        [self showPanel];
    }
}
- (void)windowWillClose:(NSNotification *)n {
    if (n.object != _panel) return;
    _panel.contentViewController = nil;
    _popover.contentViewController = _hud;
    _hud.detachBtn.image = [NSImage imageWithSystemSymbolName:@"pip.exit" accessibilityDescription:@"Detach"];
    _panel = nil;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _item.button.image = robotIcon(); _item.button.image.accessibilityDescription = @"Session HUD";
    _item.button.imagePosition = NSImageLeft; _item.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    _item.button.target = self; _item.button.action = @selector(toggle:);
    [_item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    _hud = [HUDController new];
    _popover = [NSPopover new]; _popover.contentViewController = _hud; _popover.contentSize = NSMakeSize(kWidth, 660); _popover.behavior = NSPopoverBehaviorTransient; _popover.delegate = self; _popover.animates = NO;
    [self tick]; _timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self registerHotkey];
    if (getenv("HUD_DEBUG_DETACH")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self toggleDetach:nil]; });
    if (getenv("HUD_DEBUG_SHOW")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self toggle:nil]; });
}
- (void)toggle:(id)s {
    NSEvent *e = s ? NSApp.currentEvent : nil; // nil sender = hotkey; never read a stale mouse event then
    if (e.type == NSEventTypeRightMouseUp) {
        NSMenu *m = [NSMenu new];
        NSString *term = [[NSUserDefaults standardUserDefaults] stringForKey:@"terminal"] ?: @"warp";
        NSMenuItem *w = [m addItemWithTitle:@"Resume in Warp" action:@selector(useWarp:) keyEquivalent:@""]; w.state = [term isEqualToString:@"warp"];
        NSMenuItem *t = [m addItemWithTitle:@"Resume in Terminal.app" action:@selector(useTerminal:) keyEquivalent:@""]; t.state = [term isEqualToString:@"terminal"];
        [m addItem:NSMenuItem.separatorItem];
        [m addItemWithTitle:_panel ? @"Reattach to menubar" : @"Detach to floating panel" action:@selector(toggleDetach:) keyEquivalent:@""];
        NSMenuItem *hk = [m addItemWithTitle:[NSString stringWithFormat:@"Hotkey: %@ toggles the HUD", [self hotkeyLabel]] action:nil keyEquivalent:@""]; hk.enabled = NO;
        [m addItem:NSMenuItem.separatorItem];
        [m addItemWithTitle:@"Regenerate all titles" action:@selector(resummarise:) keyEquivalent:@""];
        [m addItemWithTitle:@"Quit Session HUD" action:@selector(terminate:) keyEquivalent:@"q"];
        [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, _item.button.bounds.size.height + 4) inView:_item.button]; return;
    }
    if (getenv("HUD_DEBUG_SHOW")) NSLog(@"toggle: shown=%d buttonWindow=%@ screen=%@", _popover.isShown, _item.button.window, _item.button.window.screen);
    if (_panel) { if (_panel.isVisible) [_panel orderOut:nil]; else [self showPanel]; return; }
    if (_popover.isShown) [_popover close]; else { [self tick]; [_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSRectEdgeMinY]; [_popover.contentViewController.view.window makeFirstResponder:_hud.table]; [NSApp activateIgnoringOtherApps:YES]; }
}
- (void)closePopover:(id)s { if (_panel) return; [_popover close]; }
- (void)useWarp:(id)s { [[NSUserDefaults standardUserDefaults] setObject:@"warp" forKey:@"terminal"]; }
- (void)useTerminal:(id)s { [[NSUserDefaults standardUserDefaults] setObject:@"terminal" forKey:@"terminal"]; }
- (void)resummarise:(id)s { NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kServer stringByAppendingString:@"/resummarise"]]]; rq.HTTPMethod = @"POST"; [[[NSURLSession sharedSession] dataTaskWithRequest:rq] resume]; }
- (void)tick {
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kServer stringByAppendingString:@"/sessions"]]]; rq.timeoutInterval = 1.5;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !data) { [self serverOffline]; return; }
            NSDictionary *p = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![p isKindOfClass:NSDictionary.class]) { [self serverOffline]; return; }
            self.offline = NO;
            [self.hud setPayload:p];
            NSDictionary *c = p[@"counts"]; NSInteger ni = [c[@"needsInput"] integerValue], wk = [c[@"working"] integerValue];
            NSMutableString *t = [NSMutableString string];
            if (ni) [t appendFormat:@" %ld!", (long)ni];
            if (wk) [t appendFormat:@" %ld", (long)wk];
            self.item.button.title = t;
            if (getenv("HUD_DEBUG_SHOW")) NSLog(@"tick: total=%@ needsInput=%ld working=%ld rows=%lu", c[@"total"], (long)ni, (long)wk, (unsigned long)self.hud.rows.count);
            self.item.button.contentTintColor = ni ? NSColor.systemOrangeColor : nil; // robot turns orange when a session needs you
        });
    }] resume];
}
- (void)serverOffline {
    _offline = YES; _item.button.title = @" –"; _item.button.contentTintColor = NSColor.tertiaryLabelColor;
    _hud.header.stringValue = @"Session HUD server offline, starting it";
    if (_lastServerStart && -[_lastServerStart timeIntervalSinceNow] < 20) return;
    _lastServerStart = [NSDate date];
    NSTask *t = [NSTask new]; t.launchPath = @"/bin/zsh";
    t.arguments = @[@"-lc", [NSString stringWithFormat:@"cd %@ && mkdir -p data && nohup bun run server/index.ts >> data/server.log 2>&1 &", [kServerDir stringByExpandingTildeInPath]]];
    [t launch];
}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }
@end

static void uncaught(NSException *e) { NSLog(@"UNCAUGHT %@: %@\n%@", e.name, e.reason, e.callStackSymbols); }
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *logPath = [@"~/Library/Logs/SessionHUD.log" stringByExpandingTildeInPath];
        freopen(logPath.fileSystemRepresentation, "a", stderr);
        NSSetUncaughtExceptionHandler(&uncaught);
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [AppDelegate new]; app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
