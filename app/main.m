// Session HUD: macOS menubar app. Thin client over the Bun server at 127.0.0.1:4243.
// AppKit in Objective-C so it builds with Command Line Tools alone. Design v2 (2026-09-11).
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

static NSString *const kServer = @"http://127.0.0.1:4243";
static NSString *const kServerDir = @"~/Development/session-hud";
static const CGFloat kWidth = 560, kHeight = 680, kRowHeight = 108, kGroupHeight = 30;

// ---------- helpers ----------
static NSString *S(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static NSDate *dateOf(id isoV) {
    NSString *iso = S(isoV); if (!iso.length) return nil;
    static NSISO8601DateFormatter *f1, *f2; static dispatch_once_t once;
    dispatch_once(&once, ^{ f1 = [NSISO8601DateFormatter new]; f1.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds; f2 = [NSISO8601DateFormatter new]; f2.formatOptions = NSISO8601DateFormatWithInternetDateTime; });
    return [f1 dateFromString:iso] ?: [f2 dateFromString:iso];
}
static NSString *relTime(id isoV) {
    NSDate *d = dateOf(isoV); if (!d) return @"";
    NSTimeInterval s = -[d timeIntervalSinceNow];
    if (s < 60) return @"now";
    if (s < 3600) return [NSString stringWithFormat:@"%dm", (int)(s / 60)];
    NSCalendar *cal = NSCalendar.currentCalendar;
    if ([cal isDateInToday:d]) return [NSString stringWithFormat:@"%dh", (int)(s / 3600)];
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"HH:mm";
    if ([cal isDateInYesterday:d]) return [@"Yesterday " stringByAppendingString:[df stringFromDate:d]];
    if (s < 6 * 86400) { df.dateFormat = @"EEE HH:mm"; return [df stringFromDate:d]; }
    df.dateFormat = @"MMM d"; return [df stringFromDate:d];
}
typedef NS_ENUM(int, Bucket) { BNeeds, BWorking, BOpen, BToday, BYesterday, BWeek, BEarlier };
static Bucket bucketOf(NSDictionary *r) {
    NSString *st = S(r[@"state"]);
    if ([st isEqualToString:@"needs_input"]) return BNeeds;
    if ([st isEqualToString:@"working"]) return BWorking;
    if ([st isEqualToString:@"idle"]) return BOpen;
    NSDate *d = dateOf(r[@"lastActivityAt"]); NSCalendar *cal = NSCalendar.currentCalendar;
    if (d && [cal isDateInToday:d]) return BToday;
    if (d && [cal isDateInYesterday:d]) return BYesterday;
    if (d && -[d timeIntervalSinceNow] < 7 * 86400) return BWeek;
    return BEarlier;
}
static NSString *bucketName(Bucket b) {
    switch (b) { case BNeeds: return @"Needs input"; case BWorking: return @"Working"; case BOpen: return @"Open"; case BToday: return @"Today"; case BYesterday: return @"Yesterday"; case BWeek: return @"This week"; default: return @"Earlier"; }
}
static NSColor *stateColor(NSString *st) {
    if ([st isEqualToString:@"needs_input"]) return NSColor.systemOrangeColor;
    if ([st isEqualToString:@"working"]) return NSColor.systemGreenColor;
    if ([st isEqualToString:@"idle"]) return NSColor.systemBlueColor;
    if ([st isEqualToString:@"bg_failed"]) return NSColor.systemRedColor;
    return NSColor.quaternaryLabelColor;
}
static NSTextField *label(CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:@""];
    t.font = [NSFont systemFontOfSize:size weight:w]; t.textColor = c; t.lineBreakMode = NSLineBreakByTruncatingTail;
    t.maximumNumberOfLines = 1; t.cell.truncatesLastVisibleLine = YES; t.drawsBackground = NO;
    return t;
}
// small rounded tag: tinted background, tinted text
@interface Pill : NSTextField @end
@implementation Pill
- (NSSize)intrinsicContentSize { NSSize s = [super intrinsicContentSize]; return NSMakeSize(s.width + 14, 17); }
- (void)drawRect:(NSRect)r {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:5 yRadius:5];
    [[self.textColor colorWithAlphaComponent:0.14] setFill]; [p fill];
    [super drawRect:r];
}
@end
static Pill *pill(NSString *text, NSColor *c) {
    Pill *p = [Pill labelWithString:text]; p.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]; p.textColor = c; p.alignment = NSTextAlignmentCenter; p.drawsBackground = NO; [p sizeToFit];
    p.frame = NSMakeRect(0, 0, p.intrinsicContentSize.width, 17); return p;
}
static NSButton *actionButton(NSString *title, id target, SEL sel) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:sel];
    b.bezelStyle = NSBezelStyleRounded; b.controlSize = NSControlSizeSmall; b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    return b;
}

// ---------- menubar robot icon ----------
static NSImage *robotIcon(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 17) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor setFill];
        NSBezierPath *ant = [NSBezierPath bezierPath]; ant.lineWidth = 1.4; [ant moveToPoint:NSMakePoint(9, 12.6)]; [ant lineToPoint:NSMakePoint(9, 14.6)]; [NSColor.blackColor setStroke]; [ant stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(7.7, 14.2, 2.6, 2.6)] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.6, 5.2, 2.2, 4.4) xRadius:0.8 yRadius:0.8] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(15.2, 5.2, 2.2, 4.4) xRadius:0.8 yRadius:0.8] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.4, 1.4, 13.2, 11.4) xRadius:3.2 yRadius:3.2] fill];
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationDestinationOut];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4.9, 6.6, 3.0, 3.4) xRadius:1.1 yRadius:1.1] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(10.1, 6.6, 3.0, 3.4) xRadius:1.1 yRadius:1.1] fill];
        for (int i = 0; i < 3; i++) [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5.2 + i * 2.7, 3.2, 2.1, 1.7) xRadius:0.5 yRadius:0.5] fill];
        return YES;
    }];
    img.template = YES; return img;
}

// ---------- terminal launching ----------
@interface Launcher : NSObject
+ (void)runCommand:(NSString *)cmd cwd:(NSString *)cwd title:(NSString *)title;
+ (void)resume:(NSDictionary *)row fork:(BOOL)fork;
@end
@implementation Launcher
+ (NSString *)shellQuote:(NSString *)s { return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }
+ (void)resume:(NSDictionary *)row fork:(BOOL)fork {
    NSDictionary *r = [row[@"resume"] isKindOfClass:NSDictionary.class] ? row[@"resume"] : @{};
    NSString *cmd = S(fork ? r[@"forkCommand"] : r[@"command"]); if (!cmd.length) return;
    NSString *cwd = S(r[@"cwd"]).length ? S(r[@"cwd"]) : NSHomeDirectory();
    [self runCommand:cmd cwd:cwd title:S(row[@"title"])];
}
+ (void)runCommand:(NSString *)cmd cwd:(NSString *)cwd title:(NSString *)title {
    NSString *term = [[NSUserDefaults standardUserDefaults] stringForKey:@"terminal"] ?: @"warp";
    NSString *full = [NSString stringWithFormat:@"cd %@ && %@", [self shellQuote:cwd], cmd];
    if ([term isEqualToString:@"warp"]) {
        NSString *dir = [@"~/.warp/launch_configurations" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *q = ^(NSString *x) { return [[x stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]; }(full);
        NSString *yaml = [NSString stringWithFormat:@"name: session-hud-resume\nwindows:\n  - tabs:\n      - title: \"%@\"\n        layout:\n          cwd: \"%@\"\n          commands:\n            - exec: \"%@\"\n",
                          [title stringByReplacingOccurrencesOfString:@"\"" withString:@"'"], cwd, q];
        [yaml writeToFile:[dir stringByAppendingPathComponent:@"session-hud-resume.yaml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"warp://launch/session-hud-resume"]];
        return;
    }
    NSString *esc = [[full stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell", esc]] executeAndReturnError:&err];
    if (err) NSLog(@"Terminal launch failed: %@", err);
}
@end

// ---------- row view ----------
@interface RowView : NSTableCellView
@property NSView *dot; @property NSTextField *title, *time, *about, *leftOff, *meta, *agents; @property Pill *projectPill;
@property NSButton *resumeBtn, *btnCopy; @property NSTrackingArea *tracking; @property BOOL hovered;
@property (nonatomic) NSDictionary *row;
@end
@implementation RowView
- (instancetype)initWithFrame:(NSRect)fr {
    if ((self = [super initWithFrame:fr])) {
        _dot = [NSView new]; _dot.wantsLayer = YES; _dot.layer.cornerRadius = 4;
        _title = label(13, NSFontWeightSemibold, NSColor.labelColor);
        _time = label(11, NSFontWeightRegular, NSColor.tertiaryLabelColor); _time.alignment = NSTextAlignmentRight; _time.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        _about = label(12, NSFontWeightRegular, NSColor.secondaryLabelColor);
        _leftOff = label(12, NSFontWeightRegular, NSColor.labelColor); _leftOff.maximumNumberOfLines = 2; _leftOff.lineBreakMode = NSLineBreakByWordWrapping;
        _meta = label(10.5, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        _agents = label(10.5, NSFontWeightMedium, NSColor.systemOrangeColor); _agents.alignment = NSTextAlignmentRight;
        _projectPill = pill(@"", NSColor.secondaryLabelColor);
        _resumeBtn = actionButton(@"Resume", self, @selector(resume:)); _btnCopy = actionButton(@"Copy", self, @selector(doCopy:));
        _resumeBtn.hidden = _btnCopy.hidden = YES;
        for (NSView *v in @[_dot, _title, _time, _about, _leftOff, _meta, _agents, _projectPill, _resumeBtn, _btnCopy]) [self addSubview:v];
    }
    return self;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent *)e { _hovered = YES; [self refreshActions]; }
- (void)mouseExited:(NSEvent *)e { _hovered = NO; [self refreshActions]; }
- (void)setBackgroundStyle:(NSBackgroundStyle)s { [super setBackgroundStyle:s]; [self refreshActions]; }
- (BOOL)selected { NSTableRowView *rv = (NSTableRowView *)self.superview; return [rv isKindOfClass:NSTableRowView.class] && rv.isSelected; }
- (void)refreshActions { BOOL show = _hovered || self.selected; _resumeBtn.hidden = _btnCopy.hidden = !show; _time.hidden = show; [self setNeedsLayout:YES]; }
- (void)layout {
    [super layout];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, x = 30, right = W - 16;
    [_btnCopy sizeToFit]; [_resumeBtn sizeToFit];
    _btnCopy.frame = NSMakeRect(right - _btnCopy.frame.size.width, H - 30, _btnCopy.frame.size.width, 22);
    _resumeBtn.frame = NSMakeRect(_btnCopy.frame.origin.x - 6 - _resumeBtn.frame.size.width, H - 30, _resumeBtn.frame.size.width, 22);
    _time.frame = NSMakeRect(right - 110, H - 27, 110, 16);
    CGFloat titleRight = _resumeBtn.hidden ? _time.frame.origin.x - 8 : _resumeBtn.frame.origin.x - 8;
    _dot.frame = NSMakeRect(14, H - 22, 8, 8);
    _title.frame = NSMakeRect(x, H - 28, titleRight - x, 18);
    _about.frame = NSMakeRect(x, H - 47, right - x, 16);
    _leftOff.frame = NSMakeRect(x, H - 83, right - x, 33);
    CGFloat pw = _projectPill.stringValue.length ? _projectPill.intrinsicContentSize.width : 0;
    _projectPill.frame = NSMakeRect(x, 7, pw, 17); _projectPill.hidden = pw == 0;
    CGFloat aw = _agents.stringValue.length ? MIN(260, right - x - pw - 120) : 0;
    _agents.frame = NSMakeRect(right - aw, 8, aw, 14);
    CGFloat mx = x + (pw ? pw + 8 : 0);
    _meta.frame = NSMakeRect(mx, 8, right - aw - mx - 8, 14);
}
- (void)setRow:(NSDictionary *)row {
    _row = row;
    NSString *st = S(row[@"state"]);
    _dot.layer.backgroundColor = stateColor(st).CGColor;
    _dot.hidden = [st isEqualToString:@"ended"] || [st isEqualToString:@"bg_done"];
    _title.stringValue = S(row[@"title"]).length ? S(row[@"title"]) : @"Untitled session";
    _time.stringValue = relTime(row[@"lastActivityAt"]);
    NSString *ab = S(row[@"about"]), *lo = S(row[@"leftOff"]), *lp = S(row[@"lastPrompt"]);
    _about.stringValue = ab.length ? ab : (lp.length ? [@"“" stringByAppendingFormat:@"%@”", lp] : @"");
    if (lo.length) {
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:@"Left off  " attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}];
        [a appendAttributedString:[[NSAttributedString alloc] initWithString:lo attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.labelColor}]];
        _leftOff.attributedStringValue = a;
    } else _leftOff.stringValue = ab.length ? @"" : @"Title and summary pending…";
    NSString *proj = S(row[@"project"]);
    _projectPill.stringValue = proj; [_projectPill sizeToFit];
    NSMutableArray *parts = [NSMutableArray array];
    NSInteger turns = [row[@"turns"] isKindOfClass:NSNumber.class] ? [row[@"turns"] integerValue] : 0;
    [parts addObject:[NSString stringWithFormat:@"%ld turn%@", (long)turns, turns == 1 ? @"" : @"s"]];
    if ([st isEqualToString:@"bg_done"]) [parts addObject:@"background finished"];
    if ([st isEqualToString:@"bg_failed"]) [parts addObject:@"background failed"];
    if ([row[@"automated"] boolValue]) [parts addObject:@"automated"];
    NSString *ni = S(row[@"needsInput"]); if (ni.length) [parts addObject:ni];
    _meta.stringValue = [parts componentsJoinedByString:@"  ·  "];
    NSInteger running = [row[@"runningAgents"] integerValue]; NSArray *ag = [row[@"agents"] isKindOfClass:NSArray.class] ? row[@"agents"] : @[];
    if (running > 0) {
        NSDictionary *first = nil; for (NSDictionary *a in ag) if ([S(a[@"status"]) isEqualToString:@"running"]) { first = a; break; }
        NSString *d = S(first[@"description"]).length ? S(first[@"description"]) : S(first[@"type"]);
        _agents.stringValue = [NSString stringWithFormat:@"⟳ %ld agent%@ · %@", (long)running, running == 1 ? @"" : @"s", d];
        _agents.textColor = NSColor.systemOrangeColor;
    } else if (ag.count) { _agents.stringValue = [NSString stringWithFormat:@"%lu agent%@ done", (unsigned long)ag.count, ag.count == 1 ? @"" : @"s"]; _agents.textColor = NSColor.tertiaryLabelColor; }
    else _agents.stringValue = @"";
    NSDictionary *lv = [row[@"live"] isKindOfClass:NSDictionary.class] ? row[@"live"] : nil;
    BOOL openElsewhere = [row[@"alive"] boolValue] && [S(lv[@"kind"]) isEqualToString:@"interactive"];
    _resumeBtn.title = openElsewhere ? @"Open" : @"Resume";
    NSString *cmd = S([row[@"resume"] isKindOfClass:NSDictionary.class] ? row[@"resume"][@"command"] : nil);
    _resumeBtn.toolTip = openElsewhere ? [NSString stringWithFormat:@"Already open in a terminal (pid %@). Runs: %@", lv[@"pid"], cmd] : [@"Runs in a new terminal tab: " stringByAppendingString:cmd];
    _btnCopy.toolTip = [@"Copy: " stringByAppendingString:cmd];
    [self refreshActions];
}
- (void)drawRect:(NSRect)r {
    [super drawRect:r];
    [[NSColor.separatorColor colorWithAlphaComponent:0.6] setFill];
    NSRectFill(NSMakeRect(30, 0, self.bounds.size.width - 46, 1));
}
- (void)resume:(id)s { [Launcher resume:_row fork:NO]; [NSApp sendAction:@selector(closePopover:) to:nil from:self]; }
- (void)doCopy:(id)s {
    NSString *cmd = S([_row[@"resume"] isKindOfClass:NSDictionary.class] ? _row[@"resume"][@"command"] : nil); if (!cmd.length) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard; [pb clearContents]; [pb setString:cmd forType:NSPasteboardTypeString];
    _btnCopy.title = @"Copied"; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ self.btnCopy.title = @"Copy"; [self setNeedsLayout:YES]; });
}
@end

// ---------- group row ----------
@interface GroupView : NSTableCellView @property NSTextField *name; @property NSTextField *count; @end
@implementation GroupView
- (instancetype)initWithFrame:(NSRect)fr {
    if ((self = [super initWithFrame:fr])) {
        _name = label(10.5, NSFontWeightSemibold, NSColor.secondaryLabelColor); _count = label(10.5, NSFontWeightRegular, NSColor.tertiaryLabelColor);
        [self addSubview:_name]; [self addSubview:_count];
    }
    return self;
}
- (void)layout { [super layout]; CGFloat H = self.bounds.size.height; [_name sizeToFit]; _name.frame = NSMakeRect(14, H - 20, _name.frame.size.width, 14); _count.frame = NSMakeRect(_name.frame.origin.x + _name.frame.size.width + 6, H - 20, 60, 14); }
- (void)setTitle:(NSString *)t count:(NSUInteger)n {
    _name.attributedStringValue = [[NSAttributedString alloc] initWithString:t.uppercaseString attributes:@{NSKernAttributeName: @0.8, NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    _count.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)n]; [self setNeedsLayout:YES];
}
@end

// ---------- table with keys and context menu ----------
@interface HUDTable : NSTableView @property (weak) id keyDelegate; @end
@protocol HUDTableKeys <NSObject> - (void)tableWantsSearch; @end
@implementation HUDTable
- (void)cancelOperation:(id)s { [NSApp sendAction:@selector(closePopover:) to:nil from:self]; }
- (RowView *)rowViewAt:(NSInteger)r { id v = r >= 0 ? [self viewAtColumn:0 row:r makeIfNecessary:NO] : nil; return [v isKindOfClass:RowView.class] ? v : nil; }
- (void)moveSelection:(NSInteger)delta {
    NSInteger r = self.selectedRow, n = self.numberOfRows;
    for (int guard = 0; guard < n; guard++) { r += delta; if (r < 0 || r >= n) return; if (![self.delegate tableView:self isGroupRow:r]) break; }
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO]; [self scrollRowToVisible:r];
}
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if ([c isEqualToString:@"\r"]) { [[self rowViewAt:self.selectedRow] resume:nil]; return; }
    if ([c isEqualToString:@"c"]) { [[self rowViewAt:self.selectedRow] doCopy:nil]; return; }
    if ([c isEqualToString:@"j"]) { [self moveSelection:1]; return; }
    if ([c isEqualToString:@"k"]) { [self moveSelection:-1]; return; }
    if ([c isEqualToString:@"/"] || ([c isEqualToString:@"f"] && (e.modifierFlags & NSEventModifierFlagCommand))) { [(id<HUDTableKeys>)_keyDelegate tableWantsSearch]; return; }
    [super keyDown:e];
}
- (void)moveDown:(id)s { [self moveSelection:1]; }
- (void)moveUp:(id)s { [self moveSelection:-1]; }
- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSInteger r = [self rowAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    RowView *v = [self rowViewAt:r]; if (!v) return nil;
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
    NSMenu *m = [NSMenu new];
    [[m addItemWithTitle:@"Resume in terminal" action:@selector(ctxResume:) keyEquivalent:@""] setTarget:v];
    [[m addItemWithTitle:@"Fork into a new session" action:@selector(ctxFork:) keyEquivalent:@""] setTarget:v];
    [m addItem:NSMenuItem.separatorItem];
    [[m addItemWithTitle:@"Copy resume command" action:@selector(doCopy:) keyEquivalent:@""] setTarget:v];
    [[m addItemWithTitle:@"Copy session id" action:@selector(ctxCopyId:) keyEquivalent:@""] setTarget:v];
    [[m addItemWithTitle:@"Reveal transcript in Finder" action:@selector(ctxReveal:) keyEquivalent:@""] setTarget:v];
    return m;
}
@end
@implementation RowView (Context)
- (void)ctxResume:(id)s { [self resume:nil]; }
- (void)ctxFork:(id)s { [Launcher resume:self.row fork:YES]; [NSApp sendAction:@selector(closePopover:) to:nil from:self]; }
- (void)ctxCopyId:(id)s { NSPasteboard *pb = NSPasteboard.generalPasteboard; [pb clearContents]; [pb setString:S(self.row[@"id"]) forType:NSPasteboardTypeString]; }
- (void)ctxReveal:(id)s {
    NSString *cwd = S(self.row[@"cwd"]); NSString *slug = [[cwd stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSString *path = [[@"~/.claude/projects" stringByExpandingTildeInPath] stringByAppendingFormat:@"/%@/%@.jsonl", slug, S(self.row[@"id"])];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = [@"~/.claude/projects" stringByExpandingTildeInPath];
    [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
}
@end

// ---------- view controller ----------
@interface HUDController : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, HUDTableKeys>
@property NSArray *all, *items; @property (nonatomic) NSDictionary *payload;
@property HUDTable *table; @property NSTextField *heading, *status, *empty; @property NSView *pillBar; @property NSSegmentedControl *filter; @property NSButton *autoToggle, *detachBtn; @property NSSearchField *search;
@end
@implementation HUDController
- (void)loadView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
    CGFloat top = kHeight;
    _heading = label(15, NSFontWeightBold, NSColor.labelColor); _heading.stringValue = @"Sessions"; _heading.frame = NSMakeRect(16, top - 34, 90, 20); _heading.autoresizingMask = NSViewMinYMargin;
    _pillBar = [[NSView alloc] initWithFrame:NSMakeRect(96, top - 33, 300, 18)]; _pillBar.autoresizingMask = NSViewMinYMargin;
    _filter = [NSSegmentedControl segmentedControlWithLabels:@[@"Active", @"Week", @"All"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(refilter:)];
    _filter.selectedSegment = 0; _filter.controlSize = NSControlSizeSmall; _filter.font = [NSFont systemFontOfSize:11]; [_filter sizeToFit];
    _filter.frame = NSMakeRect(kWidth - 16 - _filter.frame.size.width, top - 36, _filter.frame.size.width, 22); _filter.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    _detachBtn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"pip.exit" accessibilityDescription:@"Detach"] target:nil action:@selector(toggleDetach:)];
    _detachBtn.bordered = NO; _detachBtn.toolTip = @"Detach to a floating panel (or drag the popover away). Close the panel to reattach."; _detachBtn.contentTintColor = NSColor.secondaryLabelColor;
    _detachBtn.frame = NSMakeRect(_filter.frame.origin.x - 8 - 24, top - 36, 24, 22); _detachBtn.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
    _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(14, top - 70, kWidth - 28 - 96, 26)]; _search.placeholderString = @"Search titles, summaries, prompts"; _search.delegate = self; _search.controlSize = NSControlSizeSmall; _search.font = [NSFont systemFontOfSize:12];
    _search.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable; _search.sendsSearchStringImmediately = YES; _search.target = self; _search.action = @selector(refilter:);
    _autoToggle = [NSButton checkboxWithTitle:@"automated" target:self action:@selector(refilter:)]; _autoToggle.controlSize = NSControlSizeSmall; _autoToggle.font = [NSFont systemFontOfSize:11]; [_autoToggle sizeToFit];
    _autoToggle.frame = NSMakeRect(kWidth - 16 - _autoToggle.frame.size.width, top - 66, _autoToggle.frame.size.width, 18); _autoToggle.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin; _autoToggle.toolTip = @"Show sessions started by crons and headless runs";
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 24, kWidth, top - 24 - 80)]; sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; sv.hasVerticalScroller = YES; sv.drawsBackground = NO; sv.autohidesScrollers = YES;
    _table = [[HUDTable alloc] initWithFrame:sv.bounds]; _table.headerView = nil; _table.rowHeight = kRowHeight; _table.intercellSpacing = NSMakeSize(0, 0);
    _table.backgroundColor = NSColor.clearColor; _table.style = NSTableViewStyleInset; _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular; _table.floatsGroupRows = NO; _table.gridStyleMask = NSTableViewGridNone;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"]; col.width = kWidth - 24; [_table addTableColumn:col];
    _table.dataSource = self; _table.delegate = self; _table.keyDelegate = self; _table.doubleAction = @selector(dbl:); _table.target = self;
    sv.documentView = _table;
    _empty = label(12, NSFontWeightRegular, NSColor.tertiaryLabelColor); _empty.alignment = NSTextAlignmentCenter; _empty.frame = NSMakeRect(0, top / 2, kWidth, 18); _empty.autoresizingMask = NSViewMinYMargin | NSViewMaxYMargin | NSViewWidthSizable; _empty.hidden = YES;
    _status = label(10.5, NSFontWeightRegular, NSColor.quaternaryLabelColor); _status.frame = NSMakeRect(16, 6, kWidth - 32, 14); _status.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable;
    for (NSView *s in @[_heading, _pillBar, _filter, _detachBtn, _search, _autoToggle, sv, _empty, _status]) [v addSubview:s];
    self.view = v;
}
- (void)dbl:(id)s { [[_table rowViewAt:_table.clickedRow] resume:nil]; }
- (void)refilter:(id)s { [self apply]; }
- (void)tableWantsSearch { [self.view.window makeFirstResponder:_search]; }
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:) || sel == @selector(insertNewline:)) { [self.view.window makeFirstResponder:_table]; if (_table.selectedRow < 0) [_table moveSelection:1]; return YES; }
    if (sel == @selector(cancelOperation:)) { if (_search.stringValue.length) { _search.stringValue = @""; [self apply]; } else { [self.view.window makeFirstResponder:_table]; [NSApp sendAction:@selector(closePopover:) to:nil from:self]; } return YES; }
    return NO;
}
- (void)controlTextDidChange:(NSNotification *)n { [self apply]; }
- (void)setPayload:(NSDictionary *)p {
    _payload = p; _all = p[@"sessions"] ?: @[];
    NSDictionary *c = p[@"counts"];
    for (NSView *sub in _pillBar.subviews.copy) [sub removeFromSuperview];
    __block CGFloat x = 0; NSInteger ni = [c[@"needsInput"] integerValue], wk = [c[@"working"] integerValue], al = [c[@"alive"] integerValue];
    void (^add)(NSString *, NSColor *) = ^(NSString *t, NSColor *col) { Pill *pl = pill(t, col); pl.frame = NSMakeRect(x, 0, pl.frame.size.width, 17); [self.pillBar addSubview:pl]; x += pl.frame.size.width + 6; };
    if (ni) add([NSString stringWithFormat:@"%ld need%@ input", (long)ni, ni == 1 ? @"s" : @""], NSColor.systemOrangeColor);
    if (wk) add([NSString stringWithFormat:@"%ld working", (long)wk], NSColor.systemGreenColor);
    add([NSString stringWithFormat:@"%ld open", (long)al], NSColor.secondaryLabelColor);
    NSInteger pend = [c[@"summariesPending"] integerValue];
    _status.stringValue = [NSString stringWithFormat:@"%@ sessions%@  ·  updated %@  ·  ⏎ resume   c copy   / search   esc close", c[@"total"], pend ? [NSString stringWithFormat:@", %ld summaries pending", (long)pend] : @"", relTime(p[@"generatedAt"])];
    [self apply];
}
- (void)apply {
    NSInteger seg = _filter.selectedSegment; BOOL showAuto = _autoToggle.state == NSControlStateValueOn;
    NSString *q = _search.stringValue.lowercaseString; BOOL searching = q.length > 0;
    NSDate *cut = [NSDate dateWithTimeIntervalSinceNow:-(seg == 0 ? 86400 : 7 * 86400)];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *r in _all) {
        if (!showAuto && [r[@"automated"] boolValue] && !searching) continue;
        if (searching) {
            NSString *hay = [[@[S(r[@"title"]), S(r[@"about"]), S(r[@"leftOff"]), S(r[@"lastPrompt"]), S(r[@"project"])] componentsJoinedByString:@" "] lowercaseString];
            if (![hay containsString:q]) continue;
        } else if (seg < 2 && ![r[@"alive"] boolValue]) {
            NSDate *d = dateOf(r[@"lastActivityAt"]); if (!d || [d compare:cut] == NSOrderedAscending) continue;
        }
        [rows addObject:r];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        Bucket ba = bucketOf(a), bb = bucketOf(b);
        if (ba != bb) return ba < bb ? NSOrderedAscending : NSOrderedDescending;
        return [S(b[@"lastActivityAt"]) compare:S(a[@"lastActivityAt"])];
    }];
    // interleave group headers
    NSMutableArray *items = [NSMutableArray array]; NSMutableArray *counts = [NSMutableArray array];
    Bucket cur = -1; NSUInteger n = 0;
    for (NSDictionary *r in rows) {
        Bucket b = bucketOf(r);
        if (b != cur) { if (items.count) [counts addObject:@(n)]; [items addObject:bucketName(b)]; cur = b; n = 0; }
        [items addObject:r]; n++;
    }
    if (items.count) [counts addObject:@(n)];
    NSMutableArray *withCounts = [NSMutableArray array]; NSUInteger ci = 0;
    for (id it in items) { if ([it isKindOfClass:NSString.class]) { [withCounts addObject:@{@"group": it, @"n": counts[ci++]}]; } else [withCounts addObject:it]; }
    NSString *selId = nil; if (_table.selectedRow >= 0 && _table.selectedRow < (NSInteger)_items.count && ![_items[_table.selectedRow][@"group"] length]) selId = S(_items[_table.selectedRow][@"id"]);
    _items = withCounts; [_table reloadData];
    _empty.hidden = rows.count > 0; _empty.stringValue = searching ? @"No sessions match" : (seg == 0 ? @"Nothing active in the last 24 hours" : @"No sessions");
    if (selId.length) { NSUInteger i = [_items indexOfObjectPassingTest:^BOOL(NSDictionary *r, NSUInteger idx, BOOL *stop) { return [S(r[@"id"]) isEqualToString:selId]; }]; if (i != NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO]; }
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return _items.count; }
- (BOOL)tableView:(NSTableView *)t isGroupRow:(NSInteger)r { return _items[r][@"group"] != nil; }
- (CGFloat)tableView:(NSTableView *)t heightOfRow:(NSInteger)r { return _items[r][@"group"] ? kGroupHeight : kRowHeight; }
- (BOOL)tableView:(NSTableView *)t shouldSelectRow:(NSInteger)r { return _items[r][@"group"] == nil; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    NSDictionary *it = _items[r];
    if (it[@"group"]) {
        GroupView *g = [t makeViewWithIdentifier:@"group" owner:self];
        if (!g) { g = [[GroupView alloc] initWithFrame:NSMakeRect(0, 0, kWidth - 24, kGroupHeight)]; g.identifier = @"group"; }
        [g setTitle:it[@"group"] count:[it[@"n"] unsignedIntegerValue]]; return g;
    }
    RowView *v = [t makeViewWithIdentifier:@"row" owner:self];
    if (!v) { v = [[RowView alloc] initWithFrame:NSMakeRect(0, 0, kWidth - 24, kRowHeight)]; v.identifier = @"row"; }
    v.row = it; return v;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n { for (NSInteger r = 0; r < _table.numberOfRows; r++) [[_table rowViewAt:r] refreshActions]; }
@end

// ---------- host for the floating panel (translucent HUD material) ----------
@interface PanelHost : NSViewController @end
@implementation PanelHost
- (void)loadView { NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)]; v.material = NSVisualEffectMaterialHUDWindow; v.blendingMode = NSVisualEffectBlendingModeBehindWindow; v.state = NSVisualEffectStateActive; self.view = v; }
@end

// ---------- app delegate ----------
@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate>
@property NSStatusItem *item; @property NSPopover *popover; @property HUDController *hud; @property NSTimer *timer; @property NSDate *lastServerStart; @property BOOL offline;
@property NSPanel *panel; @property PanelHost *host; @property EventHotKeyRef hotKeyRef;
- (void)hotkeyPressed;
@end

static OSStatus hotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    dispatch_async(dispatch_get_main_queue(), ^{ [(__bridge AppDelegate *)userData hotkeyPressed]; });
    return noErr;
}

@implementation AppDelegate
- (void)registerHotkey {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    UInt32 code = [d objectForKey:@"hotkeyKeyCode"] ? (UInt32)[d integerForKey:@"hotkeyKeyCode"] : kVK_ANSI_H;
    UInt32 mods = [d objectForKey:@"hotkeyModifiers"] ? (UInt32)[d integerForKey:@"hotkeyModifiers"] : (controlKey | optionKey);
    static BOOL installed = NO;
    if (!installed) { EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed }; InstallApplicationEventHandler(&hotKeyHandler, 1, &spec, (__bridge void *)self, NULL); installed = YES; }
    EventHotKeyID hid = { 'SHUD', 1 };
    OSStatus st = RegisterEventHotKey(code, mods, hid, GetApplicationEventTarget(), 0, &_hotKeyRef);
    NSLog(@"hotkey register keyCode=%u mods=%u status=%d", code, mods, (int)st);
    if (st != noErr) { static int attempts = 0; if (++attempts < 6) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self registerHotkey]; }); }
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
- (void)hotkeyPressed { if (_panel) { if (_panel.isVisible && _panel.isKeyWindow) [_panel orderOut:nil]; else [self showPanel]; return; } [self toggle:nil]; }
- (void)showPanel { [_panel makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [_panel makeFirstResponder:_hud.table]; }
- (NSPanel *)makePanel {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, kHeight)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    p.title = @"Session HUD"; p.level = NSFloatingWindowLevel; p.hidesOnDeactivate = NO; p.floatingPanel = YES; p.becomesKeyOnlyIfNeeded = NO;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    p.minSize = NSMakeSize(420, 260); p.delegate = self; p.releasedWhenClosed = NO;
    p.titlebarAppearsTransparent = YES; p.titleVisibility = NSWindowTitleHidden; p.movableByWindowBackground = YES; p.opaque = NO; p.backgroundColor = NSColor.clearColor;
    [p setFrameAutosaveName:@"SessionHUDPanel"];
    return p;
}
- (void)mountInPanel {
    _host = [PanelHost new]; _panel.contentViewController = _host;
    [_host addChildViewController:_hud];
    _hud.view.frame = NSInsetRect(_host.view.bounds, 0, 0); _hud.view.frame = NSMakeRect(0, 0, _host.view.bounds.size.width, _host.view.bounds.size.height - 8);
    _hud.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [_host.view addSubview:_hud.view];
    _hud.detachBtn.image = [NSImage imageWithSystemSymbolName:@"pip.enter" accessibilityDescription:@"Reattach"];
}
- (void)toggleDetach:(id)s {
    if (_panel) { [_panel close]; return; }
    [_popover close];
    _panel = [self makePanel]; _popover.contentViewController = nil; [self mountInPanel];
    if (![_panel setFrameUsingName:@"SessionHUDPanel"]) { NSRect sf = (_item.button.window.screen ?: NSScreen.mainScreen).visibleFrame; [_panel setFrameTopLeftPoint:NSMakePoint(NSMaxX(sf) - kWidth - 12, NSMaxY(sf) - 8)]; }
    [self showPanel];
}
- (BOOL)popoverShouldDetach:(NSPopover *)popover { return YES; }
- (NSWindow *)detachableWindowForPopover:(NSPopover *)popover { _panel = [self makePanel]; return _panel; }
- (void)popoverDidClose:(NSNotification *)n {
    if (_panel && _panel.contentViewController == nil) { NSRect f = _panel.frame; _popover.contentViewController = nil; [self mountInPanel]; [_panel setFrame:f display:YES]; [self showPanel]; }
}
- (void)windowWillClose:(NSNotification *)n {
    if (n.object != _panel) return;
    [_hud.view removeFromSuperview]; [_hud removeFromParentViewController];
    _panel.contentViewController = nil; _host = nil;
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
    _popover = [NSPopover new]; _popover.contentViewController = _hud; _popover.contentSize = NSMakeSize(kWidth, kHeight); _popover.behavior = NSPopoverBehaviorTransient; _popover.delegate = self; _popover.animates = NO;
    [self tick]; _timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self registerHotkey];
    if (getenv("HUD_DEBUG_DETACH")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self toggleDetach:nil]; });
    if (getenv("HUD_DEBUG_SHOW")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self toggle:nil]; });
}
- (void)toggle:(id)s {
    NSEvent *e = s ? NSApp.currentEvent : nil;
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
            self.item.button.contentTintColor = ni ? NSColor.systemOrangeColor : nil;
        });
    }] resume];
}
- (void)serverOffline {
    _offline = YES; _item.button.title = @""; _item.button.contentTintColor = NSColor.tertiaryLabelColor;
    _hud.status.stringValue = @"Server offline, starting it…";
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
        freopen([@"~/Library/Logs/SessionHUD.log" stringByExpandingTildeInPath].fileSystemRepresentation, "a", stderr);
        NSSetUncaughtExceptionHandler(&uncaught);
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [AppDelegate new]; app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
